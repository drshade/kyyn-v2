{-# LANGUAGE OverloadedStrings #-}
module Main (main) where

import Control.Monad (forM_, unless)
import Data.Aeson (Value, object, (.=), encode, toJSON)
import qualified Data.ByteString as Bytes
import qualified Data.ByteString.Lazy as Lazy
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import Effectful (runPureEff)
import Kyyn.Domain.Contract
import Kyyn.Domain.DataType
import Kyyn.Domain.EvolutionReport
import Kyyn.Domain.FileTree (files, fileTree)
import Kyyn.Domain.Path (relativeName, relativePath)
import Kyyn.Domain.Root (Root(..))
import Kyyn.Types.SchemaMetadata
import Kyyn.Types.Fact (FactId(..))
import Kyyn.Types.KnowledgeBase (KnowledgeBase(..))
import Kyyn.Plumbing.Protocol.Evolution (evolutionBindings, decodeEvolutionReply)
import Kyyn.Plumbing.Protocol.FactEdits
import Kyyn.Plumbing.Capability.DhallHandling (encodeValue, decodeValue)
import Kyyn.Plumbing.Interpreter.DhallHandling (runDhallHandling)
import Kyyn.Porcelain.Capability.EvolutionReport (checkEvolutionReport)
import Kyyn.Porcelain.Capability.RootStore (materializeRoot, loadRootValueForChecking)
import Kyyn.Porcelain.Interpreter.RootStore (runRootStore)
import System.Directory (createDirectoryIfMissing)
import System.Environment (getEnv, getEnvironment)
import System.Exit (ExitCode(..))
import System.FilePath ((</>), takeDirectory)
import System.IO.Temp (withSystemTempDirectory)
import System.Process (proc, readCreateProcessWithExitCode, CreateProcess(..))

main :: IO ()
main = withSystemTempDirectory "kyyn-fact-edits-" $ \temporary -> do
  repo <- getEnv "KYYN_TEST_ROOT"
  toolchain <- getEnv "KYYN_TEST_TOOLCHAIN"
  environment <- getEnvironment
  let todo = Algebraic "Schema.Todo" [] [Constructor "Schema.Todo" [(Just "title",StringType)]]
      fact payload = Algebraic "Kyyn.Types.Fact.Fact" [payload]
        [Constructor "Kyyn.Types.Fact.Fact" [(Nothing,sdkFactIdType),(Nothing,payload)]]
      root = Algebraic "Schema.Root" [] [Constructor "Schema.Root"
        [(Just "todos",ListType (fact todo)),(Just "flags",ListType (fact BoolType))]]
  contract <- right (checkContract root (SchemaMetadata [] []
    [CollectionDecl "tasks" "todos" [], CollectionDecl "flags" "flags" []]) >>= checkRootLayout)
  generated <- right (factEditBindings contract)
  workspace <- right (evolutionBindings contract contract)
  unless (all (`elem` files workspace) (files generated)) (fail "Workspace omitted the proposal bindings")
  forM_ (files workspace) $ \(relative,content) -> do
    let destination = temporary </> relativeName relative
    createDirectoryIfMissing True (takeDirectory destination)
    Bytes.writeFile destination content
  Bytes.writeFile (temporary </> "Schema.hs") $ Text.encodeUtf8 $ Text.unlines
    ["module Schema where", "import Kyyn.Types.Fact (Fact)",
     "data Todo = Todo { title :: String }",
     "data Root = Root { todos :: [Fact Todo], flags :: [Fact Bool] }"]
  Bytes.writeFile (temporary </> "Main.hs") $ Text.encodeUtf8 $ Text.unlines
    ["module Main where", "import Schema", "import Kyyn.Types.Fact",
     "import Kyyn.Evolution", "import Kyyn.Evolution.Proposal",
     "import Kyyn.Evolution.Internal (evaluateEvolution)",
     "import Kyyn.Workspace.FactEdits", "import KyynFactEditCodec (rootCodec)",
     "import qualified KyynEvolutionCodec1 as RootCodec", "import Kyyn.Runtime.Json",
     "import Kyyn.Runtime.Evolution",
     "main :: IO ()", "main = do", "  input <- getContents",
     "  edits <- either fail pure (parseValue input >>= decodeWith (listCodec rootCodec))",
     "  let before = KnowledgeBase (Root [Fact (FactId \"old\") (Todo \"old\")] []) []",
     "      proposal = ProposedCuration [ProposedStep (Rationale \"Apply captured edits\" []) edits] (Curation (RecipeId \"sync\") [])",
     "  either fail putStrLn (encodeEvolutionReply (knowledgeBaseCodec RootCodec.rootCodec) (evaluateEvolution (proposalEvolution proposal) before))"]
  let include = map ("-i" ++) [temporary, repo </> "guest/kyyn-sdk/src", repo </> "guest/kyyn-runtime/src",
        repo </> "shared/kyyn-types/src", repo </> "vendor/json",repo </> "vendor/transformers"]
      command binary arguments = (proc binary arguments) { cwd = Just temporary }
      native = temporary </> "native"
      artifact = temporary </> "guest.comb"
      mhsEnv = ("MHSDIR",toolchain):("MHSCPPHS",toolchain </> "bin/cpphs"):
        filter (\(key,_) -> key `notElem` ["MHSDIR","MHSCPPHS"]) environment
      compile process = do
        (status,_,errors) <- readCreateProcessWithExitCode process ""
        unless (status == ExitSuccess) (fail errors)
  compile (command "ghc-9.10.3" (["-v0","-i"] ++ include ++ ["-outputdir",temporary </> "objects","Main.hs","-o",native]))
  compile ((command (toolchain </> "bin/mhs")
    (["-DMIN_VERSION_base(x,y,z)=1","-a","-i"] ++ include ++ ["-i" ++ toolchain </> "lib","Main.hs","-o" ++ artifact])) { env = Just mhsEnv })
  shape <- right (shapeOf (ListType (factEditType contract)))
  let tagged name value = object ["tag" .= (name :: String), "value" .= value]
      todoValue value = object ["title" .= (value :: String)]
      replace ident value = tagged "Edit_todos" (tagged "Replace" (object ["factId" .= (ident :: String),"replacement" .= todoValue value]))
      appendFlag = tagged "Edit_flags" (tagged "Append" (object ["id" .= ("reviewed" :: String),"value" .= True]))
      remove = tagged "Edit_todos" (tagged "Remove" ("old" :: String))
      operations = [replace "old" "updated",appendFlag,remove]
  persisted <- right (runPureEff (runDhallHandling (encodeValue shape (toValue operations))))
  let proposalPath = temporary </> "edits.dhall"
  Bytes.writeFile proposalPath (Text.encodeUtf8 persisted)
  loaded <- Text.decodeUtf8 <$> Bytes.readFile proposalPath
  restored <- right (runPureEff (runDhallHandling (decodeValue shape loaded)))
  unless (restored == toValue operations) (fail "Dhall edit round trip changed the operations")
  let input = KnowledgeBase (object ["todos" .= [object ["id" .= ("old" :: String),"value" .= todoValue "old"]],"flags" .= ([] :: [Value])]) []
      programs = [command native [], command (toolchain </> "bin/mhseval") ["+RTS","-r" ++ artifact,"-RTS"]]
      execute process value = do
        (status,output,errors) <- readCreateProcessWithExitCode process (Text.unpack (Text.decodeUtf8 (Lazy.toStrict (encode value))))
        unless (status == ExitSuccess) (fail errors)
        right (decodeEvolutionReply (Text.encodeUtf8 (Text.pack output)))
  forM_ programs $ \program -> do
    observation <- execute program restored >>= right
    (checked@(KnowledgeBase checkedFacts _), EvolutionReport _ reports _) <- right (runPureEff (runDhallHandling (runRootStore
      (checkEvolutionReport contract input contract observation))))
    codePath <- right (relativePath "sources/Schema.hs")
    codeBytes <- Bytes.readFile (temporary </> "Schema.hs")
    code <- right (fileTree [(codePath,codeBytes)])
    stored@(Root storedContract factFiles storedCode _ _) <- right (runPureEff
      (runDhallHandling (runRootStore (materializeRoot contract code checked))))
    unless (storedContract == contract && storedCode == code) (fail "Non-fact artifacts changed")
    unless (all ((== ".dhall") . reverse . take 6 . reverse . relativeName . fst) (files factFiles))
      (fail "Facts were not materialized as Dhall")
    reloaded <- right (runPureEff (runDhallHandling (runRootStore (loadRootValueForChecking stored))))
    unless (reloaded == checkedFacts) (fail "Materialized root did not reload unchanged")
    case reports of
      [StepReport _ [FactChange "flags" (FactId "reviewed") Nothing (Just _), FactChange "tasks" (FactId "old") (Just _) Nothing]] -> pure ()
      _ -> fail ("Unexpected computed changes: " ++ show reports)
    replay <- execute program restored >>= right
    unless (replay == observation) (fail "Pure replay differs")
    rejected <- execute program (toValue [appendFlag,replace "missing" "x"])
    case rejected of Left _ -> pure (); Right _ -> fail "A failed edit returned a partial root"
  putStrLn "Generated typed fact edits passed GHC/MicroHs, Dhall replay and ordinary host observation/diff checks."

toValue :: [Value] -> Value
toValue = toJSON

right :: Show e => Either e a -> IO a
right = either (fail . show) pure
