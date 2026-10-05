-- Root/store/application integration using real Dhall/filesystem/Git and recording
-- schema/compiler/execution handlers. Includes capture, validation, candidate,
-- publication, recovery, recipes and discovery; not a real MicroHs journey.

{-# LANGUAGE DataKinds, GADTs, LambdaCase #-}
module Main (main) where

import qualified Kyyn.Types.KnowledgeBase as KB

import Kyyn.Domain.Curation (emptyCurationRegister)
import Control.Monad (unless, forM_)
import Data.Aeson (Value, object, (.=))
import qualified Data.ByteString as Bytes
import Data.List (isSuffixOf, isPrefixOf)
import Data.Text (Text)
import Effectful (Eff, runPureEff)
import Effectful.Dispatch.Dynamic (interpret)
import ExecutionTests (executionTests)
import QueryExecutionTests (queryExecutionTests)
import ValidationTests (validationTests)
import RootExportTests (rootExportTests)
import WorkspaceTests (workspaceTests)
import EvolutionCaptureTests (evolutionCaptureTests)
import CandidateTests (candidateTests)
import AcceptanceHistoryTests (acceptanceHistoryTests)
import EvolutionExecutionTests (evolutionExecutionTests)
import Kyyn.Domain.Diagnostic (errorDiagnostic)
import Kyyn.Domain.Git (Repository(..), TreePath(..), gitRevision)
import Kyyn.Domain.Contract
import Kyyn.Domain.DataType
import Kyyn.Domain.Path
import Kyyn.Domain.Root
import Kyyn.Domain.FileTree
import Kyyn.Types.SchemaMetadata
import Kyyn.Porcelain.Capability.RootStore
import Kyyn.Porcelain.Interpreter.RootStore
import Kyyn.Plumbing.Interpreter.DhallHandling
import Kyyn.Porcelain.Capability.RootOpening
import Kyyn.Porcelain.Interpreter.RootOpening
import qualified Kyyn.Plumbing.Capability.SchemaInspection as Schema
import qualified Kyyn.Plumbing.Capability.GuestCompilation.Types as Sources
import qualified Kyyn.Plumbing.Capability.Git as Git
import Kyyn.Plumbing.Capability.DhallHandling (DhallHandling)
import PublicationTests (publicationTests)
import InitializationTests (initializationTests)
import WorkspaceApiTests (workspaceApiTests)
import CurationPersistenceTests (curationPersistenceTests, sampleCuration)
import RecipeTests (recipeTests)
import RecipeInspectionTests (recipeInspectionTests)
import ToolBrokerTests (toolBrokerTests)
import Kyyn.Porcelain.Protocol.CurationPersistence (encodeRegister)

main :: IO ()
main = do
  curationPersistenceTests
  recipeTests
  toolBrokerTests
  initializationTests
  workspaceApiTests
  emptyContract <- right (checkContract
    (Algebraic "Empty.Root" [] [Constructor "Empty.Root" []]) (SchemaMetadata [] [] []) >>= checkRootLayout)
  emptyCode <- tree []
  emptyChecked <- right (runPureEff (runDhallHandling (runRootStore (checkRootValue emptyContract (object [])))))
  emptyRoot@(Root _ emptySnapshot _ _ _) <- right
    (runPureEff (runDhallHandling (runRootStore (materializeRoot emptyContract emptyCode (KB.KnowledgeBase emptyChecked [])))))
  emptyReloaded <- right (runPureEff (runDhallHandling (runRootStore (loadRootValueForChecking emptyRoot))))
  unless (emptyReloaded == emptyChecked && map (relativeName . fst) (files emptySnapshot) == ["facts/root.dhall"])
    (fail "Empty root did not round-trip through a single Dhall file")
  contract <- right (checkContract schema metadata >>= checkRootLayout)
  recipeInspectionTests contract
  other <- right (checkContract schema (SchemaMetadata [RoleDecl "label" "Changed metadata" Title] [] declarations) >>= checkRootLayout)
  code <- tree [("src/Schema.hs", "authored code"), ("kb.dhall", "selected schema")]
  checked <- right (runPureEff (runDhallHandling (runRootStore (checkRootValue contract value))))
  root@(Root _ snapshot savedCode _ _) <- right (runPureEff (runDhallHandling (runRootStore (materializeRoot contract code (KB.KnowledgeBase checked [])))))
  unless (savedCode == code) (fail "Code snapshot changed")
  unless ("facts/todos/a.dhall" `elem` map (relativeName . fst) (files snapshot)) (fail "Ordinary ID path is not readable")
  pathValue <- right (runPureEff (runDhallHandling (runRootStore (checkRootValue contract
    (rootValue [(name,"path test") | name <- ["todo-001", "A", "a", "index", "con", "com1", "~41", "", "../", "x.y", "🌍"]])))))
  pathsRoot <- right (runPureEff (runDhallHandling (runRootStore (materializeRoot contract code (KB.KnowledgeBase pathValue [])))))
  pathReloaded <- right (runPureEff (runDhallHandling (runRootStore (loadRootValueForChecking pathsRoot))))
  unless (pathReloaded == pathValue) (fail "Escaped names collided or changed IDs")
  let reopen r = runPureEff (runDhallHandling (runRootStore (loadRootValueForChecking r)))
  reopenedFiles <- right (fileTree (files snapshot))
  reopened <- right (reopen (Root contract reopenedFiles code emptyCurationRegister []))
  unless (reopened == checked) (fail "Reopening changed the root")
  rejected (runPureEff (runDhallHandling (runRootStore (materializeRoot other code (KB.KnowledgeBase checked [])))))
  forM_ [[], [("same","one"),("same","two")]] $ \items -> do
    candidate <- right (runPureEff (runDhallHandling (runRootStore (checkRootValue contract (rootValue items)))))
    case items of
      [] -> do
        empty@(Root _ emptyFiles _ _ _) <- right (runPureEff (runDhallHandling (runRootStore (materializeRoot contract code (KB.KnowledgeBase candidate [])))))
        emptyValue <- right (reopen empty)
        unless (emptyValue == candidate && length (files emptyFiles) == 2) (fail "Empty collection not retained")
      _ -> rejected (runPureEff (runDhallHandling (runRootStore (materializeRoot contract code (KB.KnowledgeBase candidate [])))))
  forM_ (files snapshot) $ \(path,_) -> do
    missing <- right (fileTree (filter ((/= path) . fst) (files snapshot)))
    rejected (reopen (Root contract missing code emptyCurationRegister []))
  extra <- tree [("facts/unlisted.dhall", "{}")]
  unlisted <- right (fileTree (files snapshot ++ files extra))
  rejected (reopen (Root contract unlisted code emptyCurationRegister []))
  forM_ ["[\"a\", \"a\"]", "[\"missing\"]", "[\"a\"]", "[\"../\"]", "[] : List Text"] $ \index -> do
    changed <- right (fileTree [(p, if "index.dhall" `isSuffixOf` relativeName p then index else b) | (p,b) <- files snapshot])
    rejected (reopen (Root contract changed code emptyCurationRegister []))
  let damage replacement = fileTree [(p, if relativeName p == "facts/todos/a.dhall" then replacement else b) | (p,b) <- files snapshot]
  forM_ ["{ id = \"wrong\", value = { title = \"one\" } }", Bytes.pack [255]] $ \bad -> do
    corrupt <- right (damage bad)
    rejected (reopen (Root contract corrupt code emptyCurationRegister []))
  overlap <- tree [("facts/extra", "not code")]
  rejected (runPureEff (runDhallHandling (runRootStore (materializeRoot contract overlap (KB.KnowledgeBase checked [])))))
  a <- right (relativePath "a")
  ab <- right (relativePath "a/b")
  rejected (fileTree [(a,""),(a,"")])
  rejected (fileTree [(a,""),(ab,"")])
  unless (root == Root contract snapshot code emptyCurationRegister []) (fail "Snapshot mutated")
  orderA <- tree [("a/c","one"),("a-b","two")]
  orderB <- tree [("a-b","two"),("a/c","one")]
  unless (orderA == orderB) (fail "FileTree depends on producer ordering")
  openingTests contract snapshot
  workspaceTests
  evolutionCaptureTests contract
  evolutionExecutionTests contract snapshot
  executionTests contract snapshot
  queryExecutionTests contract snapshot
  validationTests contract snapshot
  candidateTests contract snapshot
  acceptanceHistoryTests
  rootExportTests root
  publicationTests root
  putStrLn "Root materialization/reopening, identities, membership and corruption checks passed."

openingTests :: RootContract -> FileTree -> IO ()
openingTests contract factFiles = do
  authored <- tree [("src/Example.hs","authored source"),("kb.dhall",manifest),
    ("examples/retained.txt","required-example material"),("support.dhall","auxiliary code")]
  captured <- right (fileTree (files authored ++ files factFiles))
  sdk <- tree [("Kyyn/Types/Fact.hs","installed SDK")]
  let execute :: FileTree -> Eff '[RootOpening, RootStore, Git.Git, Schema.SchemaInspection, DhallHandling] a -> a
      execute sdkFiles action = runPureEff (runDhallHandling (schemaMock (rootSchema contract) (gitMock captured
        (runRootStore (runRootOpening sdkFiles action)))))
  opened <- right (execute sdk (openCapturedRoot captured))
  progressBytes <- right (runPureEff (runDhallHandling (encodeRegister sampleCuration)))
  withProgress <- right (fileTree ((curationLocation,progressBytes) : files captured))
  progressed <- right (execute sdk (openCapturedRoot withProgress))
  unless (progressed == Root contract factFiles authored sampleCuration []) (fail "Opening lost host-owned curation")
  progressSource <- right (execute sdk (openCapturedSource withProgress))
  unless (progressSource == SourceRoot contract authored (either (error . show) id
      (runPureEff (runDhallHandling (runRootStore (readRootDefinition authored))))) [])
    (fail "Source-only target includes curation material")
  unless (opened == Root contract factFiles authored emptyCurationRegister []) (fail "Opening changed the selected files")
  definition <- right (runPureEff (runDhallHandling (runRootStore (readRootDefinition authored))))
  source <- right (execute sdk (openCapturedSource captured))
  unless (source == SourceRoot contract authored definition []) (fail "Source opening changed schema/code/definition")
  sourceWithoutFacts <- right (execute sdk (openCapturedSource authored))
  unless (sourceWithoutFacts == source) (fail "Source opening depends on facts")
  corrupt <- tree [("facts/root.dhall", "not Dhall"), ("facts/unknown.bin", Bytes.pack [255,0])]
  withCorruptFacts <- right (fileTree (files authored ++ files corrupt))
  corruptSource <- right (execute sdk (openCapturedSource withCorruptFacts))
  unless (corruptSource == source) (fail "Source opening decoded corrupt facts")
  rejected (execute sdk (openCapturedRoot withCorruptFacts))
  repo <- Repository <$> right (directoryScope "/unused-test-repository")
  revision <- right (gitRevision (replicate 40 'a'))
  prefix <- right (relativePath "root")
  fromGit <- right (execute sdk (loadRootAt repo revision (Subtree prefix)))
  unless (fromGit == opened) (fail "Git opening differs from captured opening")
  sourceFromGit <- right (execute sdk (loadSourceAt repo revision (Subtree prefix)))
  unless (sourceFromGit == source) (fail "Source loading differs from captured source opening")
  input <- right (execute sdk (loadRootMaterialAt repo revision (Subtree prefix) sourceFromGit))
  unless (input == opened) (fail "Input capture changed prepared source or root bytes")
  progressedInput <- right (runPureEff . runDhallHandling . schemaMock (rootSchema contract)
    . gitMock withProgress . runRootStore . runRootOpening sdk $
      loadRootMaterialAt repo revision (Subtree prefix) sourceFromGit)
  unless (progressedInput == progressed) (fail "Evolution input omitted accepted curation")
  let undecoded = runPureEff . runDhallHandling . schemaMock (rootSchema contract)
        . gitMock withCorruptFacts . runRootStore . runRootOpening sdk $
          loadRootMaterialAt repo revision (Subtree prefix) sourceFromGit
  corruptInput <- right undecoded
  unless (corruptInput == Root contract corrupt authored emptyCurationRegister []) (fail "Input capture decoded or changed malformed facts")
  otherRevision <- right (gitRevision (replicate 40 'b'))
  rejected (execute sdk (loadSourceAt repo otherRevision (Subtree prefix)))
  rejected (execute sdk (loadSourceAt repo revision WholeTree))
  forM_ ["kb.dhall", "src/Example.hs"] $ \missing -> do
    incomplete <- right (fileTree (filter ((/= missing) . relativeName . fst) (files authored)))
    rejected (execute sdk (openCapturedSource incomplete))
  forM_ [filter ((/= "kb.dhall") . relativeName . fst) (files captured),
    [(p,if relativeName p == "kb.dhall" then "True" else b) | (p,b) <- files captured],
    [(p,if relativeName p == "kb.dhall" then "{ schemaType = \"Missing.Root\", schemaMetadata = \"Example.schemaMetadata\", validator = \"Example.validate\" , queries = [] : List { name : Text, description : Text, implementation : Text, inputType : Text, inputMetadata : Text, resultType : Text, resultMetadata : Text }, tools = [] : List { name : Text, description : Text, implementation : Text, inputType : Text, resultType : Text } }" else b) | (p,b) <- files captured],
    [(p,if relativeName p == "kb.dhall" then "{ schemaType = \"Example.Root\", schemaMetadata = \"Example.otherMetadata\", validator = \"Example.validate\" , queries = [] : List { name : Text, description : Text, implementation : Text, inputType : Text, inputMetadata : Text, resultType : Text, resultMetadata : Text }, tools = [] : List { name : Text, description : Text, implementation : Text, inputType : Text, resultType : Text } }" else b) | (p,b) <- files captured],
    filter ((/= "facts/root.dhall") . relativeName . fst) (files captured)] $ \entries -> do
      bad <- right (fileTree entries)
      rejected (execute sdk (openCapturedRoot bad))
  collision <- tree [("Example.hs","SDK collision")]
  rejected (execute collision (openCapturedRoot captured))
  rejected (execute sdk (loadRootAt repo revision WholeTree))
  where
    manifest = "{ schemaType = \"Example.Root\", schemaMetadata = \"Example.schemaMetadata\", validator = \"Example.validate\" , queries = [] : List { name : Text, description : Text, implementation : Text, inputType : Text, inputMetadata : Text, resultType : Text, resultMetadata : Text }, tools = [] : List { name : Text, description : Text, implementation : Text, inputType : Text, resultType : Text } }"

schemaMock :: CheckedContract -> Eff (Schema.SchemaInspection : es) a -> Eff es a
schemaMock contract = interpret $ \_ -> \case
  Schema.InspectPluginFunction {} -> error "Unexpected plugin signature inspection"
  Schema.InspectImports {} -> error "Unexpected import inspection"
  Schema.InspectType {} -> error "Unexpected plain type inspection"
  Schema.InspectSchema source ->
    let entries = [(relativeName p,b) | (p,b) <- Sources.sourceFiles (Schema.schemaSources source)]
    in pure $ if Schema.selectedType source == "Example.Root" &&
         lookup "Example.hs" entries == Just "authored source" && lookup "Kyyn/Types/Fact.hs" entries == Just "installed SDK" &&
         maybe False (Bytes.isInfixOf "Example.schemaMetadata") (lookup "KyynMetadataEntry.hs" entries)
       then Right (Schema.InspectedSchema contract []) else Left [errorDiagnostic "test.schema" "Incorrect source capture"]

gitMock :: FileTree -> Eff (Git.Git : es) a -> Eff es a
gitMock captured = interpret $ \_ -> \case
  Git.FetchRevision {} -> error "Root opening must not refresh remote packages"
  Git.CloneRepository {} -> error "Root opening must not acquire remote packages"
  Git.SourceChanges {} -> error "Root opening must not inspect plugin source changes"
  Git.ReadUserIdentity _ -> error "Root opening must not read commit identity"
  Git.DiscoverRepository _ -> error "Root opening unexpectedly discovered a repository"
  Git.InitializeRepository _ -> error "Root opening must not initialize a repository"
  Git.IndexPaths {} -> error "Root opening must not inspect the index"
  Git.ResolveRevision _ _ -> error "RootOpening must not resolve the revision again"
  Git.ReadTreeAt _ revision (Subtree prefix) []
    | Right revision == gitRevision (replicate 40 'a') && relativeName prefix == "root" -> pure (Right captured)
    | Right revision == gitRevision (replicate 40 'a') && relativeName prefix == "root/facts" ->
        pure (Right (either error id (fileTree [(either error id (relativePath (drop 6 (relativeName p))),b)
          | (p,b) <- files captured, "facts/" `isPrefixOf` relativeName p])))
  Git.ReadTreeAt _ revision (Subtree prefix) excluded
    | Right revision == gitRevision (replicate 40 'a') && relativeName prefix == "root"
      && map relativeName excluded == ["facts", "curation.dhall", "recipes.dhall"] ->
        pure (Right (either error id (fileTree [(p,b) | (p,b) <- files captured,
          not (isRootMaterial p)])))
  Git.ReadTreeAt {} -> pure (Left [errorDiagnostic "test.git" "Unusable source selection"])
  Git.CreateCommit {} -> error "RootOpening must not create commits"
  Git.CompareAndSwapRef {} -> error "RootOpening must not publish refs"
  Git.ReadFileAt _ revision path
    | Right revision == gitRevision (replicate 40 'a') && relativeName path == "root/recipes.dhall" ->
        pure (Right (lookup recipesLocation (files captured)))
    | Right revision == gitRevision (replicate 40 'a') && relativeName path == "root/curation.dhall" ->
        pure (Right (lookup curationLocation (files captured)))
  Git.ReadFileAt {} -> error "RootOpening read unexpected material"
  Git.ReadCommitParents {} -> error "RootOpening must not traverse history"
  Git.ReadDirectoryAt _ revision (Subtree prefix)
    | Right revision == gitRevision (replicate 40 'a') && relativeName prefix == "root/facts" -> pure (Right (Just []))
  Git.ReadDirectoryAt {} -> error "RootOpening listed an unexpected directory"
  Git.CheckedOutBranch {} -> error "RootOpening must not inspect the checkout"
  Git.CheckoutChanges {} -> error "RootOpening must not inspect the checkout"
  Git.SynchronizeCheckout {} -> error "RootOpening must not synchronize the checkout"

right :: Show e => Either e a -> IO a
right = either (fail . show) pure

rejected :: Show a => Either e a -> IO ()
rejected (Left _) = pure ()
rejected (Right value') = fail ("Unexpected success: " ++ show value')

tree :: [(FilePath, Bytes.ByteString)] -> IO FileTree
tree entries = do
  paths <- traverse (\(p,b) -> do path <- right (relativePath p); pure (path,b)) entries
  right (fileTree paths)

value :: Value
value = rootValue [("a", "one"), ("A/../🌍", "two")]

rootValue :: [(Text,Text)] -> Value
rootValue items = object ["description" .= ("kept outside collections" :: Text), "todos" .=
  [object ["id" .= identity, "value" .= object ["title" .= title]] | (identity,title) <- items]]

declarations :: [CollectionDecl]
declarations = [CollectionDecl "todos" "todos" []]

metadata :: SchemaMetadata
metadata = SchemaMetadata [] [] declarations

schema :: DataType
schema = Algebraic "Example.Root" [] [Constructor "Example.Root"
  [(Just "description",StringType),(Just "todos", ListType fact)]]
  where
    fact = Algebraic "Kyyn.Types.Fact.Fact" [payload]
      [Constructor "Kyyn.Types.Fact.Fact" [(Nothing,sdkFactIdType),(Nothing,payload)]]
    payload = Algebraic "Example.Todo" [] [Constructor "Example.Todo" [(Just "title",StringType)]]
