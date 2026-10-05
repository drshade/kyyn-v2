-- Actual EvolutionExecution with MicroHs/RootOpening/Dhall and recorded Git input:
-- schema-changing chain, source closure, materialization/reopen and context.
-- Does not save candidates or publish proposals.

{-# LANGUAGE GADTs, OverloadedStrings #-}
module Main (main) where

import qualified Kyyn.Types.KnowledgeBase as KB

import Kyyn.Domain.Curation (emptyCurationRegister)
import Control.Monad (unless)
import Data.Aeson (object, (.=))
import qualified Data.ByteString as Bytes
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import Effectful (Eff, runEff, runPureEff)
import Effectful.Dispatch.Dynamic (interpret)
import Kyyn.Domain.Contract
import Kyyn.Domain.DataType
import Kyyn.Domain.Evolution
import Kyyn.Domain.EvolutionReport
import Kyyn.Domain.FileTree
import Kyyn.Domain.Git
import Kyyn.Domain.KnowledgeBase
import Kyyn.Domain.Path
import Kyyn.Domain.Root
import Kyyn.Domain.Workspace
import Kyyn.Types.SchemaMetadata
import Kyyn.Plumbing.Capability.Git (Git(..))
import Kyyn.Plumbing.Interpreter.DhallHandling
import Kyyn.Plumbing.Interpreter.Failure
import Kyyn.Plumbing.Interpreter.FileSystem
import Kyyn.Plumbing.Interpreter.ProcessExecution
import Kyyn.MicroHs.Toolchain
import Kyyn.MicroHs.Interpreter.GuestCompilation
import Kyyn.MicroHs.Interpreter.GuestExecution (runGuestExecution)
import Kyyn.MicroHs.Interpreter.SchemaInspection
import Kyyn.Porcelain.Capability.EvolutionExecution
import Kyyn.Porcelain.Capability.RootStore
import Kyyn.Porcelain.Capability.RootOpening (loadSourceAt, openCapturedSource)
import Kyyn.Porcelain.Interpreter.RootStore
import Kyyn.Porcelain.Interpreter.RootOpening
import Kyyn.Porcelain.Interpreter.EvolutionExecution
import System.Environment (getEnv)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)

main :: IO ()
main = withSystemTempDirectory "kyyn-workspace-evolution" $ \temporary -> do
  repo <- getEnv "KYYN_TEST_ROOT"
  compiler <- getEnv "KYYN_TEST_TOOLCHAIN"
  scope <- right (directoryScope temporary)
  toolchain <- GuestToolchain <$> right (directoryScope compiler)
  let path = either error id . relativePath
      load base name = (,) (path name) <$> Bytes.readFile (repo </> base </> name)
      utf8 = Text.encodeUtf8 . Text.pack
      tree = either error id . fileTree
  sdk <- sequence
    ([load "shared/kyyn-types/src" ("Kyyn/Types/" ++ name ++ ".hs") | name <- ["Fact","Diagnostic","Evidence","Curation","KnowledgeBase","Evolution","Program","SchemaMetadata"]] ++
     [load "guest/kyyn-sdk/src" name | name <- ["Kyyn/Schema.hs","Kyyn/Validation.hs","Kyyn/Evolution.hs","Kyyn/Evolution/Internal.hs","Kyyn/Evolution/KnowledgeBase.hs","Kyyn/Edit.hs","Kyyn/Edit/Internal.hs","Kyyn/Optics.hs"]] ++
     [load "guest/kyyn-runtime/src" ("Kyyn/Runtime/" ++ name ++ ".hs") | name <- ["Json","Evolution","Validation","SchemaMetadata"]] ++
     [load "vendor/transformers" name | name <- ["Control/Monad/Signatures.hs","Control/Monad/Trans/Class.hs","Control/Monad/Trans/Reader.hs","Control/Monad/Trans/State/Strict.hs"]] ++
     [load "vendor/json" name | name <- ["Text/JSON/Types.hs","Text/JSON/String.hs"]]) >>= right . fileTree
  oldSchema <- load "host/kyyn-microhs/test/evolution" "SchemaV1.hs"
  newSchema <- load "host/kyyn-microhs/test/evolution" "SchemaV2.hs"
  entry <- load "host/kyyn-microhs/test/evolution" "Evolution.hs"
  beforeContract <- right (checkContract beforeType metadata >>= checkRootLayout)
  let oldMetadata = unlines ["module Metadata where", "import Kyyn.Schema",
        "metadata :: SchemaMetadata", "metadata = SchemaMetadata [RoleDecl \"title\" \"Title\" Title] [] [CollectionDecl \"todos\" \"todos\" []]"]
      checks namespace body = utf8 (unlines ["module Checks where", "import " ++ namespace, "import Kyyn.Validation",
        "validate :: Root -> ValidationReport", "validate _ = " ++ body])
      before = tree [oldSchema,(path "Metadata.hs",utf8 oldMetadata),
        (path "Checks.hs",checks "SchemaV1" "ValidationReport [Diagnostic Error \"old-rule\" \"Needs repair\" Nothing]")]
      targetSources = tree [newSchema,(path "Metadata.hs",utf8 oldMetadata),
        (path "Checks.hs",checks "SchemaV2" "ValidationReport []")]
      code namespace sources = tree ((path "kb.dhall",utf8 (manifest namespace)) :
        [(path ("src/" ++ relativeName p),bytes) | (p,bytes) <- files sources])
      beforeCode = code "SchemaV1" before
      target = code "SchemaV2" targetSources
      input = object ["todos" .= [object ["id" .= ("todo-001" :: String),"value" .= object ["title" .= ("Review" :: String)]]]]
      expected = object ["todos" .= [object ["id" .= ("todo-001" :: String),"value" .= object ["title" .= ("Review λ" :: String),"done" .= True]]]]
      rootAction = do
        value <- checkRootValue beforeContract input
        either (pure . Left) (\v -> materializeRoot beforeContract beforeCode (KB.KnowledgeBase v [])) value
  Root _ factFiles _ _ _ <- right (runPureEff (runDhallHandling (runRootStore rootAction)))
  revision <- right (gitRevision (replicate 40 'a'))
  identifier <- right (evolutionId "abc")
  let repository = Repository scope
      kb = KnowledgeBase repository (Subtree (path "nested"))
      snapshot = WorkspaceSnapshot (WorkspaceManifest revision "Migrate" "Review" Draft)
        before target (tree [entry]) (tree [])
      context = EvolutionContext kb identifier (Before revision beforeContract) snapshot
      acceptedTree = tree (files beforeCode ++ files factFiles)
  result <- runEff . runFailure . runProcessExecutionIO . runFileSystemIO scope . runGuestExecution toolchain . runGuestCompilation toolchain Nothing
    . runDhallHandling . runSchemaInspectionIO toolchain Nothing . gitMock repository revision acceptedTree
    . runRootStore . runRootOpening sdk . runEvolutionExecution sdk $ do
      SourceRoot selected codeFiles _ closure <- loadSourceAt repository revision (Subtree (path "nested/root")) >>= either (error . show) pure
      prepared <- openCapturedSource target >>= either (error . show) pure
      evaluateEvolution (CapturedEvolution context (Root selected factFiles codeFiles emptyCurationRegister []) closure prepared)
  EvaluatedEvolution preserved (After afterContract) checked@(KB.KnowledgeBase (CheckedValue _ value) recipes) (EvolutionReport _ reports _) <- right result >>= right
  unless ((case preserved of CapturedEvolution actual _ _ _ -> actual == context) && value == expected && length reports == 3 &&
      all (\(StepReport _ changes) -> length changes == 1) reports)
    (fail ("Unexpected evaluated workspace: " ++ show result))
  materialized <- right (runPureEff (runDhallHandling (runRootStore (materializeRoot afterContract target checked))))
  reopened <- right (runPureEff (runDhallHandling (runRootStore (loadRootValueForChecking materialized))))
  unless (checked == KB.KnowledgeBase reopened recipes) (fail "Evaluated After did not materialize and reopen exactly")
  putStrLn "Captured workspace evaluated through real schema inspection, MicroHs and checked reports; exact After materialized and reopened."

gitMock :: Repository -> GitRevision -> FileTree -> Eff (Git : es) a -> Eff es a
gitMock repository revision tree = interpret $ \_ operation -> case operation of
  ReadTreeAt selected selectedRevision (Subtree path) excluded
    | selected == repository && selectedRevision == revision && relativeName path == "nested/root"
      && excluded == [factsLocation, curationLocation, recipesLocation] -> pure (Right (either error id (fileTree [(p,b) | (p,b) <- files tree, not (isRootMaterial p)])))
  _ -> error "Evolution attempted Git operations other than its exact Before read"

beforeType :: DataType
beforeType = Algebraic "SchemaV1.Root" [] [Constructor "SchemaV1.Root" [(Just "todos",ListType fact)]]
  where
    payload = Algebraic "SchemaV1.Todo" [] [Constructor "SchemaV1.Todo" [(Just "title",StringType)]]
    fact = Algebraic "Kyyn.Types.Fact.Fact" [payload]
      [Constructor "Kyyn.Types.Fact.Fact" [(Nothing,sdkFactIdType),(Nothing,payload)]]

metadata :: SchemaMetadata
metadata = SchemaMetadata [RoleDecl "title" "Title" Title] [] [CollectionDecl "todos" "todos" []]

manifest :: String -> String
manifest namespace = "{ schemaType = " ++ show (namespace ++ ".Root") ++
  ", schemaMetadata = \"Metadata.metadata\", validator = \"Checks.validate\", queries = [] : List { name : Text, description : Text, implementation : Text, inputType : Text, inputMetadata : Text, resultType : Text, resultMetadata : Text }, tools = [] : List { name : Text, description : Text, implementation : Text, inputType : Text, resultType : Text } }"

right :: Show e => Either e a -> IO a
right = either (fail . show) pure
