module Main (main) where

import Control.Monad (forM_, unless, void)
import Data.Aeson (Value(..), eitherDecode, object, (.=))
import qualified Data.Aeson.Key as Key
import qualified Data.Aeson.KeyMap as Keys
import qualified Data.ByteString as Bytes
import qualified Data.ByteString.Lazy as Lazy
import Data.List (isInfixOf)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import Effectful (runPureEff)
import Kyyn.Domain.Contract
import Kyyn.Domain.DataType (DataType(..))
import Kyyn.Domain.Example
import Kyyn.Domain.FileTree (files)
import Kyyn.Domain.Path (relativeName)
import Kyyn.Domain.Query (QueryDescriptor(..))
import Kyyn.Domain.Root (CheckedValue(..))
import Kyyn.Types.SchemaMetadata (SchemaMetadata(..))
import Kyyn.Porcelain.Capability.RootStore (encodeExample)
import Kyyn.Porcelain.Interpreter.RootStore (runRootStore)
import Kyyn.Plumbing.Interpreter.DhallHandling (runDhallHandling)
import System.Directory
import System.Environment (getEnv, getEnvironment)
import System.Exit (ExitCode(..))
import System.FilePath ((</>), takeDirectory)
import System.IO (hSetBuffering, stdout, BufferMode(..))
import System.IO.Temp (withSystemTempDirectory)
import System.Process (proc, readCreateProcessWithExitCode, CreateProcess(..))

main :: IO ()
main = do
  hSetBuffering stdout LineBuffering
  repository <- getEnv "KYYN_TEST_ROOT"
  executable <- getEnv "KYYN_TEST_CLI"
  environment <- getEnvironment
  let identity = [("GIT_AUTHOR_NAME","Ignored override"),("GIT_AUTHOR_EMAIL","ignored@example.invalid"),
        ("GIT_COMMITTER_NAME","Ignored override"),("GIT_COMMITTER_EMAIL","ignored@example.invalid")]
      fixtureEnvironment = identity ++ filter (\(key,_) -> key `notElem` map fst identity) environment
  withSystemTempDirectory "kyyn-installed-journey" $ \kb -> do
    copyTree (repository </> "examples/todos") kb
    let root = kb </> "root"
        fixture = repository </> "host/kyyn/test/journey"
        git arguments = do
          (status,output,errors) <- readCreateProcessWithExitCode
            ((proc "git" arguments) {cwd = Just kb, env = Just fixtureEnvironment}) ""
          unless (status == ExitSuccess) (fail (show arguments ++ errors))
          pure (filter (/= '\n') output)
        cli :: ExitCode -> [String] -> IO Value
        cli expected arguments = do
          putStrLn ("kyyn " ++ unwords arguments)
          (status,output,errors) <- readCreateProcessWithExitCode
            ((proc executable (["--kb",kb,"--json"] ++ arguments)) {env = Just fixtureEnvironment}) ""
          unless (status == expected) (fail (show arguments ++ "\n" ++ show status ++ "\n" ++ output ++ errors))
          either fail pure (eitherDecode (Lazy.fromStrict (Text.encodeUtf8 (Text.pack output))))
        ok = cli ExitSuccess
        create label = do
          response <- ok ["evolution","new",label]
          identifier <- textAt ["result","id"] response
          workspace <- textAt ["result","path"] response
          pure (identifier,workspace)
    writeUtf8 (root </> "kb.dhall") (manifest "TodoSchemaV1")
    copyFile (fixture </> "Queries.hs") (root </> "src/Queries.hs")
    saveExample root "receipts-title" "titleFor" StringType (String "todo-002") (String "Check receipts")
    void (git ["init","-b","main"])
    void (git ["config","user.name","Configured fixture λ"])
    void (git ["config","user.email","fixture@example.invalid"])
    void (git ["add","."])
    void (git ["commit","-m","Initial todos with a required example"])
    before <- git ["rev-parse","HEAD"]
    void (ok ["root","check"])

    (first,workspace) <- create "simplify-todos"
    assert "First evolution did not use a numbered slug" (first == "000001-simplify-todos")
    void (git ["config","user.name",""])
    missingIdentity <- cli (ExitFailure 1) ["--runtime",kb </> "missing-runtime","evolution","accept",first]
    assert "Missing identity did not refuse before runtime loading"
      (any (\diagnostic -> at ["code"] diagnostic == String "git.identity") (array (at ["diagnostics"] missingIdentity)))
    void (git ["config","user.name","Configured fixture λ"])
    let target = workspace </> "target"
    removeFile (target </> "src/TodoSchemaV1.hs")
    copyFile (fixture </> "TodoSchemaV2.hs") (target </> "src/TodoSchemaV2.hs")
    forM_ ["Queries.hs","Validate.hs"] $ \name -> do
      source <- Text.unpack . Text.decodeUtf8 <$> Bytes.readFile (target </> "src" </> name)
      writeUtf8 (target </> "src" </> name) (replace "TodoSchemaV1" "TodoSchemaV2" source)
    writeUtf8 (target </> "kb.dhall") (manifest "TodoSchemaV2")
    saveExample target "report-done" "isDone" BoolType (String "todo-001") (Bool True)
    copyFile (fixture </> "Migrate.hs") (workspace </> "change/Evolution.hs")
    evaluated <- ok ["evolution","check",first]
    let report = at ["result","report"] evaluated
    assert "Three composed steps were not reported" (length (array (at ["steps"] report)) == 3)
    unchanged <- git ["rev-parse","HEAD"]
    assert "Evaluation changed HEAD" (before == unchanged)
    void (ok ["evolution","ready",first])
    accepted <- ok ["evolution","accept",first]
    after <- git ["rev-parse","HEAD"]
    parent <- git ["rev-parse","HEAD^"]
    assert "Acceptance did not create one step" (parent == before && after /= before)
    accepting <- textAt ["result","acceptingCommit"] accepted
    assert "Reported acceptance differs from Git" (accepting == after)
    actualIdentity <- git ["log","-1","--format=%an <%ae>|%cn <%ce>"]
    assert "Acceptance ignored configured Git identity or used environment overrides"
      (actualIdentity == "Configured fixture λ <fixture@example.invalid>|Configured fixture λ <fixture@example.invalid>")
    void (git ["config","user.name",""])
    retried <- cli (ExitFailure 4) ["--runtime",kb </> "missing-runtime","evolution","accept",first]
    retryRevision <- textAt ["result","revision"] retried
    assert "Accepted retry lost its original revision" (retryRevision == after)
    void (git ["config","user.name","Configured fixture λ"])
    commitMessage <- git ["log","-1","--format=%s"]
    assert "Commit omitted the evolution name" ("simplify-todos" `isInfixOf` commitMessage)
    oldCurrent <- doesFileExist (root </> "src/TodoSchemaV1.hs")
    oldArchived <- doesFileExist (workspace </> "before/TodoSchemaV1.hs")
    assert "Schema replacement lost its archive or retained old current source" (not oldCurrent && oldArchived)

    renameDirectory (kb </> ".kyyn") (kb </> "discarded-cache")
    archived <- ok ["--runtime",kb </> "missing-runtime","evolution","show",first]
    assert "Archived rationale/report changed" (at ["result","report"] archived == report)
    reopened <- ok ["root","show"]
    assert "Wrong accepted facts" (at ["result","value"] reopened == expectedFacts)

    (second,secondWorkspace) <- create "remove-report"
    assert "Accepted workspace did not count toward the sequence" (second == "000002-remove-report")
    copyFile (fixture </> "Delete.hs") (secondWorkspace </> "change/Evolution.hs")
    void (cli (ExitFailure 1) ["evolution","check",second])
    void (ok ["evolution","ready",second])
    rejected <- cli (ExitFailure 1) ["evolution","accept",second]
    assert "Inherited example did not explain rejection"
      (any (\diagnostic -> at ["location","name"] diagnostic == String "report-done")
        (array (at ["diagnostics"] rejected)))
    stillAfter <- git ["rev-parse","HEAD"]
    assert "Rejected acceptance moved HEAD" (stillAfter == after)

    -- Deliberately retire the assertion along with the fact; this is authored input.
    removeDirectoryRecursive (secondWorkspace </> "target/examples/report-done")
    void (ok ["evolution","check",second])
    void (ok ["evolution","accept",second])
    removed <- doesFileExist (root </> "facts/todos/todo-001.dhall")
    removedExample <- doesDirectoryExist (root </> "examples/report-done")
    assert "Acceptance failed to remove fact/example files" (not removed && not removedExample)
    final <- ok ["root","show"]
    let finalFacts = object ["todos" .= drop 1 (array (at ["todos"] expectedFacts))]
    assert "Wrong facts after deletion" (at ["result","value"] final == finalFacts)
    putStrLn "Installed CLI schema migration, archive/cache independence, inherited-example refusal and deliberate deletion passed."

saveExample :: FilePath -> String -> String -> DataType -> Value -> Value -> IO ()
saveExample destination name query resultType arguments expected = do
  input <- right (checkContract StringType (SchemaMetadata [] [] []))
  result <- right (checkContract resultType (SchemaMetadata [] [] []))
  tree <- right (runPureEff (runDhallHandling (runRootStore (encodeExample
    (Example name (QueryDescriptor query "" input result)
      (CheckedValue (contractId input) arguments) (CheckedValue (contractId result) expected)
      Required "Keep this behaviour when evolving the KB.")))))
  forM_ (files tree) $ \(path,bytes) -> do
    let target = destination </> relativeName path
    createDirectoryIfMissing True (takeDirectory target)
    Bytes.writeFile target bytes

manifest :: String -> String
manifest schema = "{ schemaType = " ++ show (schema ++ ".Root") ++
  ", schemaMetadata = " ++ show (schema ++ ".metadata") ++
  ", validator = \"Validate.validate\", queries = [" ++ declaration "titleFor" "Result" ++
  "," ++ declaration "isDone" "DoneResult" ++ "], recipes = [] : List { name : Text, instructions : Text }, tools = [] : List { name : Text, description : Text, implementation : Text, inputType : Text, resultType : Text } }"
  where
    declaration name result = "{ name = " ++ show name ++ ", description = \"Todo query\", implementation = " ++
      show ("Queries." ++ name) ++ ", inputType = \"Queries.Input\", inputMetadata = \"Queries.metadata\", resultType = " ++
      show ("Queries." ++ result) ++ ", resultMetadata = \"Queries.metadata\" }"

expectedFacts :: Value
expectedFacts = object ["todos" .=
  [ fact "todo-001" "Write sales report λ" "Done"
  , fact "todo-002" "Check receipts" "Open"
  , fact "todo-003" "Review sales report" "Open" ]]
  where
    fact :: String -> String -> String -> Value
    fact identity title status = object ["id" .= identity,
      "value" .= object ["title" .= title,"status" .= object ["tag" .= status]]]

at :: [Text.Text] -> Value -> Value
at [] value = value
at (key:rest) (Object values) = maybe Null (at rest) (Keys.lookup (Key.fromText key) values)
at _ _ = Null

array :: Value -> [Value]
array (Array values) = foldr (:) [] values
array _ = []

textAt :: [Text.Text] -> Value -> IO String
textAt path value = case at path value of
  String text -> pure (Text.unpack text)
  other -> fail ("Missing string at " ++ show path ++ ": " ++ show other)

assert :: String -> Bool -> IO ()
assert message condition = unless condition (fail message)

right :: Show e => Either e a -> IO a
right = either (fail . show) pure

writeUtf8 :: FilePath -> String -> IO ()
writeUtf8 path = Bytes.writeFile path . Text.encodeUtf8 . Text.pack

copyTree :: FilePath -> FilePath -> IO ()
copyTree source target = do
  createDirectoryIfMissing True target
  names <- listDirectory source
  forM_ names $ \name -> do
    directory <- doesDirectoryExist (source </> name)
    if directory then copyTree (source </> name) (target </> name)
      else copyFile (source </> name) (target </> name)

replace :: String -> String -> String -> String
replace old new input
  | take (length old) input == old = new ++ replace old new (drop (length old) input)
replace old new (x:xs) = x : replace old new xs
replace _ _ [] = []
