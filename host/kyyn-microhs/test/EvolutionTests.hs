{-# LANGUAGE OverloadedStrings #-}
module Main (main) where

import Control.Monad (unless, forM_)
import qualified Data.ByteString as Bytes
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import Effectful (runEff, runPureEff)
import Kyyn.Domain.EvolutionReport
import Kyyn.Types.Evolution
import Kyyn.Types.Diagnostic
import Kyyn.Porcelain.Capability.EvolutionReport
import Kyyn.Porcelain.Interpreter.RootStore
import Kyyn.Plumbing.Interpreter.DhallHandling
import Kyyn.Domain.Contract
import Kyyn.Domain.DataType
import Kyyn.Domain.FileTree (FileTree, files, fileTree)
import Kyyn.Domain.Path
import Kyyn.Types.SchemaMetadata
import Kyyn.Plumbing.Protocol.Evolution (evolutionBindings, identityEvolutionSource, decodeEvolutionReply)
import Kyyn.Plumbing.Capability.GuestCompilation
import Kyyn.Plumbing.Capability.GuestExecution (executeCompiled)
import Kyyn.Plumbing.Capability.ProcessExecution
import Kyyn.Plumbing.Interpreter.Failure
import Kyyn.Plumbing.Interpreter.FileSystem
import Kyyn.Plumbing.Interpreter.ProcessExecution
import Kyyn.MicroHs.Toolchain
import Kyyn.MicroHs.Interpreter.GuestCompilation
import Kyyn.MicroHs.Interpreter.GuestExecution (runGuestExecution)
import System.Directory (createDirectoryIfMissing)
import System.Environment (getArgs, getEnv)
import System.Exit (ExitCode(..))
import System.FilePath ((</>), takeDirectory)
import System.IO.Temp (withSystemTempDirectory)
import System.Process (proc, readCreateProcessWithExitCode, CreateProcess(..))

main :: IO ()
main = do
  let bare = Algebraic "Schema.Item" [] []
      applied = Algebraic "Schema.Box" [bare] []
  forM_ [(bare,"Schema.Item"), (applied,"(Schema.Box Schema.Item)"),
         (Algebraic "Schema.Box" [applied] [],"(Schema.Box (Schema.Box Schema.Item))")] $ \(t,expected) ->
    unless (haskellType t == expected) (fail "Schema type rendering changed application grouping")
  before <- checked "SchemaV1" [(Just "title",StringType)] "Title"
  renamed <- checked "SchemaV1" [(Just "title",StringType)] "New label"
  after <- checked "SchemaV2" [(Just "title",StringType),(Just "done",BoolType)] "Title"
  bindings <- right (evolutionBindings before after)
  metadataBindings <- right (evolutionBindings before renamed)
  let fingerprints = [contractFingerprint (contractId (rootSchema contract)) | contract <- [before,renamed,after]]
      source = Bytes.concat (map snd (files bindings ++ files metadataBindings))
  unless (all (\fingerprint -> Text.encodeUtf8 (Text.pack fingerprint) `Bytes.isInfixOf` source) fingerprints)
    (fail "Generated bindings lost their whole contract identities")
  named <- right (checkContract (rootType (rootSchema before))
    (SchemaMetadata [] [] [CollectionDecl "work items" "todos" []]) >>= checkRootLayout)
  namedBindings <- right (evolutionBindings named named)
  let generated = [(relativeName p,b) | (p,b) <- files namedBindings]
  forM_ ["Before","After"] $ \endpoint -> do
    let endpointSource = lookup ("Kyyn/Workspace/" ++ endpoint ++ ".hs") generated
    forM_ ["todos = Internal.Collection \"work items\"",
           "import Kyyn.Edit (Collection)",
           "-- | Collection \"work items\" in SchemaV1.Root.\n-- Root field: todos; fact type: SchemaV1.Todo.\ntodos :: Collection SchemaV1.Root SchemaV1.Todo"] $ \expected ->
      unless (maybe False (Bytes.isInfixOf expected) endpointSource)
        (fail "Collection binding lost its public signature, documentation or logical name")
  forM_ ["-- | Transform the Before root, SchemaV1.Root, into the After root, SchemaV2.Root.",
         "-- | Edit the Before root, SchemaV1.Root, without changing its schema.",
         "-- | Edit the After root, SchemaV2.Root, without changing its schema.",
         "-- The supplied rationale describes one recorded step and its diff."] $ \expected ->
    unless (expected `Bytes.isInfixOf` source)
      (fail "Generated evolution documentation lost endpoint or rationale details")
  getArgs >>= \args -> case args of
    ["--pure"] -> pure ()
    [] -> integration before renamed after bindings
    _ -> fail "usage: evolutions [--pure]"

checked :: String -> [(Maybe String,DataType)] -> String -> IO RootContract
checked moduleName fields label = right $ checkContract root metadata >>= checkRootLayout
  where
    todo = Algebraic (moduleName ++ ".Todo") [] [Constructor (moduleName ++ ".Todo") fields]
    fact = Algebraic "Kyyn.Types.Fact.Fact" [todo]
      [Constructor "Kyyn.Types.Fact.Fact" [(Nothing,sdkFactIdType),(Nothing,todo)]]
    root = Algebraic (moduleName ++ ".Root") [] [Constructor (moduleName ++ ".Root") [(Just "todos",ListType fact)]]
    metadata = SchemaMetadata [RoleDecl "title" label Title] [] [CollectionDecl "todos" "todos" []]

integration :: RootContract -> RootContract -> RootContract -> FileTree -> IO ()
integration before renamed after bindings = withSystemTempDirectory "kyyn-evolution-proof" $ \temporary -> do
  repo <- getEnv "KYYN_TEST_ROOT"
  compiler <- getEnv "KYYN_TEST_TOOLCHAIN"
  scope <- right (directoryScope temporary)
  toolchain <- GuestToolchain <$> right (directoryScope compiler)
  let path = either error id . relativePath
      load base name = (,) (path name) <$> Bytes.readFile (repo </> base </> name)
  authored <- mapM (load "host/kyyn-microhs/test/evolution") ["SchemaV1.hs","SchemaV2.hs","Evolution.hs","Proof.hs"]
  metadataBindings <- renamedBindings "Metadata" before renamed
  sameBindings <- renamedBindings "Unchanged" before before
  support <- sequence
    ([load "shared/kyyn-types/src" ("Kyyn/Types/" ++ name ++ ".hs") | name <- ["Fact","Diagnostic","Evidence","Curation","KnowledgeBase","Evolution","Program","SchemaMetadata"]] ++
     [load "guest/kyyn-sdk/src" name | name <- ["Kyyn/Schema.hs","Kyyn/Validation.hs","Kyyn/Evolution.hs","Kyyn/Evolution/Internal.hs","Kyyn/Evolution/KnowledgeBase.hs","Kyyn/Edit.hs","Kyyn/Edit/Internal.hs","Kyyn/Optics.hs"]] ++
     [load "guest/kyyn-sdk/test" name | name <- ["EvolutionCore.hs","EditTests.hs","KnowledgeBaseTests.hs"]] ++
     [load "guest/kyyn-runtime/src" ("Kyyn/Runtime/" ++ name ++ ".hs") | name <- ["Json","Evolution","Validation"]] ++
     [load "vendor/transformers" name | name <- ["Control/Monad/Signatures.hs","Control/Monad/Trans/Class.hs","Control/Monad/Trans/Reader.hs","Control/Monad/Trans/State/Strict.hs"]] ++
     [load "vendor/json" name | name <- ["Text/JSON/Types.hs","Text/JSON/String.hs"]])
  let identitySource = Text.encodeUtf8 (Text.replace "module Evolution where" "module Identity where" (Text.decodeUtf8 (identityEvolutionSource "SchemaV1.Root")))
      captured = (path "Identity.hs",identitySource) : authored ++ support ++ files bindings ++ files metadataBindings ++ files sameBindings
      compileGuestFiles entries = do
        sources <- right (guestSources (path "Proof.hs") entries)
        runEff . runFailure . runProcessExecutionIO . runFileSystemIO scope . runGuestCompilation toolchain $ compileGuest sources
      native label entries = do
        let directory = temporary </> label
        forM_ entries $ \(relative,bytes) -> do
          let target = directory </> relativeName relative
          createDirectoryIfMissing True (takeDirectory target)
          Bytes.writeFile target bytes
        readCreateProcessWithExitCode ((proc "ghc"
          ["-v0","-i","-i.","-outputdir","build","-main-is","Proof.main","Proof.hs","-o","proof"]){cwd=Just directory}) ""
  (nativeStatus,_,nativeError) <- native "native" captured
  unless (nativeStatus == ExitSuccess) (fail nativeError)
  (status,expected,errors) <- readCreateProcessWithExitCode (proc (temporary </> "native/proof") []) ""
  unless (status == ExitSuccess) (fail errors)
  compiled <- compileGuestFiles captured >>= right >>= right
  guest <- runEff . runFailure . runProcessExecutionIO . runFileSystemIO scope . runGuestExecution toolchain $
    executeCompiled compiled Bytes.empty
  actual <- right guest
  unless (actual == (Text.encodeUtf8 (Text.pack expected),ProcessExit 0 "")) (fail ("GHC/MicroHs evolution proof differed: " ++ show actual))
  replies <- traverse (right . decodeEvolutionReply . Text.encodeUtf8 . Text.pack)
    [line | line <- lines expected, take 1 line == "{"]
  case replies of
    [Right observation@(EvolutionObservation _ (StepObservation _ (ObservedRoot _ input) _ : _) _), Left refusal] -> do
      (_,EvolutionReport reports _) <- right (runPureEff . runDhallHandling . runRootStore $
        checkEvolutionReport before input after observation)
      unless (length reports == 3 && all (\(StepReport _ changes) -> length changes == 1) reports)
        (fail "Guest observations did not derive the three real fact changes")
      unless (refusal == EvolutionFailure [Diagnostic Error "evolution.refused" "Cannot reconcile λ"
        (Just (FactLocation "todos" "todo-001" (Just "title")))]) (fail "Guest refusal lost its structured diagnostic")
    _ -> fail "Expected successful guest observations and a separate refusal"
  let badType = [(p,if relativeName p == "Evolution.hs"
        then Text.encodeUtf8 (Text.replace "editBefore" "edit" (Text.decodeUtf8 b)) else b) | (p,b) <- captured]
      badConstructor = [(p,if relativeName p == "Proof.hs" then
        "module Proof where\nimport Kyyn.Evolution\nmain :: IO ()\nmain = print (EvolutionOutput () [] Nothing)\n" else b) | (p,b) <- captured]
      badBinding = [(p,if relativeName p == "Proof.hs" then
        "module Proof where\nimport Kyyn.Workspace.Evolution (beforeRoot)\nmain :: IO ()\nmain = pure ()\n" else b) | (p,b) <- captured]
      hiddenCollection = [(p,if relativeName p == "Proof.hs" then
        "module Proof where\nimport Kyyn.Edit\nmain :: IO ()\nmain = let c = Collection \"fake\" (lens id (\\_ v -> v)) in c `seq` pure ()\n" else b) | (p,b) <- captured]
      hiddenExecutor = [(p,if relativeName p == "Proof.hs" then
        "module Proof where\nimport Kyyn.Edit (execStateT)\nmain :: IO ()\nmain = pure ()\n" else b) | (p,b) <- captured]
  forM_ [("wrong-type",badType),("private-constructor",badConstructor),("hidden-binding",badBinding),
    ("hidden-collection",hiddenCollection),("hidden-executor",hiddenExecutor)] $ \(label,entries) -> do
    (nativeRejected,_,_) <- native label entries
    unless (nativeRejected /= ExitSuccess) (fail (label ++ " compiled under GHC"))
    rejected <- compileGuestFiles entries
    case rejected of
      Right (Left _) -> pure ()
      Left failure -> fail (show failure)
      Right (Right _) -> fail (label ++ " compiled under MicroHs")
  putStr expected
  putStrLn "GHC and MicroHs agree; wrong binding types and private constructors are rejected."

renamedBindings :: String -> RootContract -> RootContract -> IO FileTree
renamedBindings name before after = do
  generated <- right (evolutionBindings before after)
  let rename = Text.replace "KyynEvolutionCodec" (Text.pack ("Kyyn" ++ name ++ "Codec")) .
        Text.replace "Kyyn.Workspace.Evolution" (Text.pack ("Kyyn.Workspace." ++ name)) .
        Text.replace "Kyyn/Workspace/Evolution" (Text.pack ("Kyyn/Workspace/" ++ name))
  entries <- traverse (\(p,b) -> do
    renamed <- right (relativePath (Text.unpack (rename (Text.pack (relativeName p)))))
    pure (renamed,Text.encodeUtf8 (rename (Text.decodeUtf8 b))))
    [(p,b) | (p,b) <- files generated, relativeName p `notElem` ["Kyyn/Workspace/Before.hs","Kyyn/Workspace/After.hs"]]
  right (fileTree entries)

right :: Show e => Either e a -> IO a
right = either (fail . show) pure
