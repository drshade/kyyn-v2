{-# LANGUAGE GADTs, OverloadedStrings, LambdaCase #-}
module ExecutionTests (executionTests) where

import Kyyn.Domain.Curation (emptyCurationRegister)
import Control.Monad (unless, forM_)
import qualified Data.ByteString as Bytes
import Effectful (Eff, runEff)
import Effectful.Dispatch.Dynamic (interpret)
import Kyyn.Domain.Contract (RootContract)
import Kyyn.Domain.Diagnostic (Diagnostic, ValidationReport(..), errorDiagnostic)
import Kyyn.Domain.Failure (OperationalFailure(..), ProcessDiagnostic(..), ProcessOperation(..))
import Kyyn.Domain.FileTree (FileTree, fileTree)
import Kyyn.Domain.Path (relativePath, relativeName, directoryScope)
import Kyyn.Domain.Root (Root(..))
import Kyyn.Plumbing.Capability.GuestCompilation (GuestCompilation(..))
import Kyyn.Plumbing.Capability.SchemaInspection (SchemaInspection)
import Kyyn.Plumbing.Capability.GuestCompilation.Types (sourceFiles)
import Kyyn.Domain.CompiledProgram (CompiledProgram)
import GuestFixture
import Kyyn.Plumbing.Interpreter.DhallHandling (runDhallHandling)
import Kyyn.Plumbing.Interpreter.Failure (runFailure)
import Kyyn.Plumbing.Interpreter.FileSystem (runFileSystemIO)
import Kyyn.Plumbing.Interpreter.ProcessExecution (runProcessExecutionIO)
import Kyyn.Porcelain.Capability.RootExecution (prepareRoot, validateRoot)
import Kyyn.Porcelain.Interpreter.RootExecution (runRootExecution)
import Kyyn.Porcelain.Interpreter.ToolPreparation (runToolPreparation)
import Kyyn.Porcelain.Interpreter.PluginPreparation (runPluginPreparation)
import Kyyn.Porcelain.Interpreter.RootStore (runRootStore)
import System.Directory (findExecutable)
import System.IO.Temp (withSystemTempDirectory)

executionTests :: RootContract -> FileTree -> IO ()
executionTests contract facts = withSystemTempDirectory "kyyn-root-execution" $ \directory -> do
  scope <- either fail pure (directoryScope directory)
  shell <- findExecutable "sh" >>= maybe (fail "sh required for process failure fixtures") pure
  let path = either error id . relativePath
      tree = either error id . fileTree
      manifest = "{ schemaType = \"Example.Root\", schemaMetadata = \"Example.schemaMetadata\", validator = \"Checks.validate\" , queries = [] : List { name : Text, description : Text, implementation : Text, inputType : Text, inputMetadata : Text, resultType : Text, resultMetadata : Text }, recipes = [] : List { name : Text, instructions : Text }, tools = [] : List { name : Text, description : Text, implementation : Text, inputType : Text, resultType : Text } }"
      code = tree [(path "src/Checks.hs", "captured validator"), (path "kb.dhall", manifest)]
      sdk = tree [(path "Sdk.hs", "explicit SDK")]
      root = Root contract facts code emptyCurationRegister
      entry = fixtureProgram
      execute sdkFiles compilation selected = runEff . runFailure . runProcessExecutionIO . runFileSystemIO scope
        . runFixtureExecution shell . compileMock compilation . noInspection . runDhallHandling . runRootStore . runPluginPreparation sdkFiles . runToolPreparation sdkFiles . runRootExecution sdkFiles $ do
          prepared <- prepareRoot selected
          either (pure . Left) validateRoot prepared
      unexpected = error "Invalid root reached compilation"
  success <- execute sdk (Right (entry "printf '[]'")) root
  unless (success == Right (Right (ValidationReport []))) (fail (show success))
  let compilerErrors = [errorDiagnostic "guest.compiler-rejected" "wrong validator type"]
  rejected <- execute sdk (Left compilerErrors) root
  unless (rejected == Right (Left compilerErrors)) (fail "Compilation rejection became a semantic report")
  crashed <- execute sdk (Right (entry "exit 17")) root
  case crashed of
    Left (RuntimeUnavailable (ProcessDiagnostic WaitForExit _)) -> pure ()
    _ -> fail ("Validator exit did not remain Failure: " ++ show crashed)
  malformed <- execute sdk (Right (entry "printf '{}'")) root
  case malformed of
    Left (RuntimeUnavailable (ProcessDiagnostic ReadOutput _)) -> pure ()
    _ -> fail ("Malformed report became semantic diagnostics: " ++ show malformed)
  forM_ [tree [], tree [(path "kb.dhall", "True")],
      tree [(path "kb.dhall", "{ schemaType = \"Example.Root\", schemaMetadata = \"Example.schemaMetadata\" }")],
      tree [(path "kb.dhall", "{ schemaType = \"Example.Root\", schemaMetadata = \"Example.schemaMetadata\", validator = \"\" , queries = [] : List { name : Text, description : Text, implementation : Text, inputType : Text, inputMetadata : Text, resultType : Text, resultMetadata : Text }, recipes = [] : List { name : Text, instructions : Text }, tools = [] : List { name : Text, description : Text, implementation : Text, inputType : Text, resultType : Text } }")],
      tree [(path "kb.dhall", "{ schemaType = \"Example.Root\", schemaMetadata = \"Example.schemaMetadata\", validator = \"Checks.validate;bad\" , queries = [] : List { name : Text, description : Text, implementation : Text, inputType : Text, inputMetadata : Text, resultType : Text, resultMetadata : Text }, recipes = [] : List { name : Text, instructions : Text }, tools = [] : List { name : Text, description : Text, implementation : Text, inputType : Text, resultType : Text } }")]] $ \badCode -> do
    failure <- execute sdk unexpected (Root contract facts badCode emptyCurationRegister)
    case failure of Right (Left _) -> pure (); _ -> fail "Invalid manifest reached execution"
  noFacts <- execute sdk (Right (entry "exit 99")) (Root contract (tree []) code emptyCurationRegister)
  case noFacts of Right (Left _) -> pure (); _ -> fail "Unreadable facts reached execution"
  collision <- execute (tree [(path "Checks.hs", "collision")]) unexpected root
  case collision of Right (Left _) -> pure (); _ -> fail "Source collision reached compilation"
  putStrLn "RootExecution manifest/source selection and structural/compiler/runtime failure distinctions passed."

compileMock :: Either [Diagnostic] CompiledProgram -> Eff (GuestCompilation : es) a -> Eff es a
compileMock result = interpret $ \_ -> \case
  CompileGuest captured -> do
    let entries = [(relativeName path,bytes) | (path,bytes) <- sourceFiles captured]
    unless (lookup "Checks.hs" entries == Just "captured validator" &&
        lookup "Sdk.hs" entries == Just "explicit SDK" &&
        lookup "KyynQueryBindings.hs" entries /= Nothing &&
        maybe False (Bytes.isInfixOf "validate = Checks.validate") (lookup "KyynValidationEntry.hs" entries) &&
        maybe False (Bytes.isInfixOf "rootCodec") (lookup "KyynValidationCodec.hs" entries))
      (error "RootExecution did not compile captured sources with explicit SDK and adapter")
    pure result

noInspection :: Eff (SchemaInspection : es) a -> Eff es a
noInspection = interpret $ \_ _ -> error "Validation unexpectedly inspected query contracts"
