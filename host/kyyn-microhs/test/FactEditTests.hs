-- Generated same-schema edits under GHC/MicroHs, real Dhall proposals and RootStore
-- materialization. Checks rationale/curation, reports, repeated frozen evaluation and
-- failure without partial state; no CLI acceptance or live model.

{-# LANGUAGE OverloadedStrings #-}
module Main (main) where

import Control.Monad (forM_, unless)
import Data.Aeson (Value, object, (.=), encode)
import qualified Data.ByteString as Bytes
import qualified Data.ByteString.Lazy as Lazy
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import Effectful (runPureEff)
import Kyyn.Domain.Contract
import Kyyn.Domain.DataType
import Kyyn.Domain.EvolutionReport
import Kyyn.Domain.FactProposal
import Kyyn.Domain.FileTree (files, fileTree)
import Kyyn.Domain.Path (relativeName, relativePath)
import Kyyn.Domain.Root (Root(..))
import Kyyn.Types.SchemaMetadata
import Kyyn.Types.Fact (FactId(..))
import Kyyn.Types.Evolution (Rationale(..))
import Kyyn.Types.Evidence (EvidenceRef(..), EvidenceId(..))
import Kyyn.Types.Curation
import Kyyn.Types.KnowledgeBase (KnowledgeBase(..))
import Kyyn.Plumbing.Protocol.Evolution (evolutionBindings, decodeEvolutionReply)
import Kyyn.Plumbing.Protocol.FactEdits
import Kyyn.Plumbing.Protocol.FactProposal
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
     "import Kyyn.Runtime.Evolution", "import Kyyn.Runtime.Proposal (proposalCodec)", "import qualified Evolution",
     "main :: IO ()", "main = do", "  input <- getContents",
     "  selected <- if input == \"\\\"frozen\\\"\" then pure Evolution.evolution else either fail (pure . proposalEvolution) (parseValue input >>= decodeWith (proposalCodec rootCodec))",
     "  let before = KnowledgeBase (Root [Fact (FactId \"old\") (Todo \"old\")] []) []",
     "  either fail putStrLn (encodeEvolutionReply (knowledgeBaseCodec RootCodec.rootCodec) (evaluateEvolution selected before))"]
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
  shape <- right (proposalShape contract)
  let tagged name value = object ["tag" .= (name :: String), "value" .= value]
      todoValue value = object ["title" .= (value :: String)]
      replace ident value = tagged "Edit_todos" (tagged "Replace" (object ["factId" .= (ident :: String),"replacement" .= todoValue value]))
      appendFlag = tagged "Edit_flags" (tagged "Append" (object ["id" .= ("reviewed" :: String),"value" .= True]))
      remove = tagged "Edit_todos" (tagged "Remove" ("old" :: String))
      operations = [replace "old" "updated",appendFlag,remove]
      why = Rationale "Apply captured edits λ" [EvidenceRef "files" "inbox" "file:///todo" ["old"]]
      curation = Curation (RecipeId "sync") [EntireBatch (EvidenceScope "files" "inbox" "first"),
        IndividualRecords (EvidenceScope "files" "other" "second") [EvidenceId "deleted"]]
      proposal edits = FactProposal [FactProposalStep why edits] curation
  persisted <- right (runPureEff (runDhallHandling (encodeValue shape (proposalValue (proposal operations)))))
  let proposalPath = temporary </> "proposal.dhall"
  Bytes.writeFile proposalPath (Text.encodeUtf8 persisted)
  loaded <- Text.decodeUtf8 <$> Bytes.readFile proposalPath
  restored <- right (runPureEff (runDhallHandling (decodeValue shape loaded)))
  unless (restored == proposalValue (proposal operations)) (fail "Dhall proposal round trip changed the operations")
  change <- right (runPureEff (runDhallHandling (proposalChange contract (proposal operations))))
  entryPath <- right (relativePath "Evolution.hs")
  entry <- maybe (fail "Missing frozen entry") (pure . Text.decodeUtf8) (lookup entryPath (files change))
  unless ("evolution = frozen\n" `Text.isInfixOf` entry
      && not ("proposal.decode" `Text.isInfixOf` entry)
      && not ("case " `Text.isInfixOf` entry))
    (fail "Frozen entry leaked proposal decoding into authored code")
  renamed <- right (checkContract root (SchemaMetadata [] []
    [CollectionDecl "renamed" "todos" [], CollectionDecl "flags" "flags" []]) >>= checkRootLayout)
  case runPureEff (runDhallHandling (lowerProposal contract renamed change)) of
    Left _ -> pure ()
    Right _ -> fail "Proposal accepted changed endpoint metadata"
  invalidPath <- right (relativePath "proposal.dhall")
  invalidChange <- right (fileTree [(invalidPath,"True")])
  case runPureEff (runDhallHandling (lowerProposal contract contract invalidChange)) of
    Left _ -> pure ()
    Right _ -> fail "Malformed Dhall reached the guest compiler"
  lowered <- right (runPureEff (runDhallHandling (lowerProposal contract contract change)))
  forM_ (files lowered) $ \(relative,bytes) -> Bytes.writeFile (temporary </> relativeName relative) bytes
  compile (command "ghc-9.10.3" (["-v0","-i"] ++ include ++ ["-outputdir",temporary </> "objects","Main.hs","-o",native]))
  compile ((command (toolchain </> "bin/mhs")
    (["-DMIN_VERSION_base(x,y,z)=1","-a","-i"] ++ include ++ ["-i" ++ toolchain </> "lib","Main.hs","-o" ++ artifact])) { env = Just mhsEnv })
  let input = KnowledgeBase (object ["todos" .= [object ["id" .= ("old" :: String),"value" .= todoValue "old"]],"flags" .= ([] :: [Value])]) []
      programs = [command native [], command (toolchain </> "bin/mhseval") ["+RTS","-r" ++ artifact,"-RTS"]]
      execute process value = do
        (status,output,errors) <- readCreateProcessWithExitCode process (Text.unpack (Text.decodeUtf8 (Lazy.toStrict (encode value))))
        unless (status == ExitSuccess) (fail errors)
        right (decodeEvolutionReply (Text.encodeUtf8 (Text.pack output)))
  forM_ programs $ \program -> do
    observation <- execute program restored >>= right
    (checked@(KnowledgeBase checkedFacts _), EvolutionReport _ reports handled) <- right (runPureEff (runDhallHandling (runRootStore
      (checkEvolutionReport contract input contract observation))))
    unless (handled == Just curation && all (\(StepReport rationale _) -> rationale == why) reports)
      (fail "Proposal rationale, citations or acknowledgements changed")
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
    frozen <- execute program ("frozen" :: Value) >>= right
    unless (frozen == observation) (fail "Generated frozen evolution differs from returned proposal")
    rejected <- execute program (proposalValue (proposal [appendFlag,replace "missing" "x"]))
    case rejected of Left _ -> pure (); Right _ -> fail "A failed edit returned a partial root"
  putStrLn "Generated typed fact edits passed GHC/MicroHs, Dhall replay and ordinary host observation/diff checks."

right :: Show e => Either e a -> IO a
right = either (fail . show) pure
