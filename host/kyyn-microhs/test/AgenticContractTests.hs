-- Generate Agentic contracts from checked types and compile under GHC/MicroHs.
-- Covers records/sums/optionals/FactIds/exact integers, exhaustive Probability wire/model
-- roundtrips, malformed retry and unsupported shapes; no live provider or CLI acceptance.

{-# LANGUAGE OverloadedStrings #-}
module Main (main) where

import Control.Monad (forM_, unless)
import qualified Data.ByteString as Bytes
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import Kyyn.Domain.DataType
import Kyyn.Domain.FileTree (files)
import Kyyn.Domain.Path (relativeName)
import Kyyn.Plumbing.Capability.SchemaInspection.Agentic (generateAgenticCodec, generateAgenticInstance)
import Kyyn.Plumbing.Capability.SchemaInspection.Codecs (generateCodecs)
import System.Directory (createDirectoryIfMissing, listDirectory, doesDirectoryExist)
import System.Environment (getEnv, getEnvironment)
import System.Exit (ExitCode(..))
import System.FilePath ((</>), takeDirectory)
import System.IO.Temp (withSystemTempDirectory)
import System.Process (proc, readCreateProcessWithExitCode, CreateProcess(..))

main :: IO ()
main = withSystemTempDirectory "kyyn-agentic-contracts-" $ \temporary -> do
  repo <- getEnv "KYYN_TEST_ROOT"
  toolchain <- getEnv "KYYN_TEST_TOOLCHAIN"
  environment <- getEnvironment
  stageAgentic (repo </> "vendor/agentic/src") temporary
  let status = Algebraic "Schema.Status" [] [Constructor "Schema.Open" [],Constructor "Schema.Done" []]
      choice = Algebraic "Schema.Choice" [] [Constructor "Schema.Named" [(Nothing,StringType)],
        Constructor "Schema.Confidence" [(Nothing,ProbabilityType)],
        Constructor "Schema.Counted" [(Just "count",IntegerType),(Just "enabled",BoolType)]]
      payload = Algebraic "Schema.Payload" [] [Constructor "Schema.Payload"
        [(Just "status",status),(Just "choices",ListType choice),(Just "note",OptionalType StringType),
         (Just "number",IntegerType),(Just "identity",sdkFactIdType), (Just "confidence", OptionalType ProbabilityType)]]
  generated <- right (generateAgenticCodec "Generated" payload)
  probabilityModel <- right (generateAgenticCodec "ProbabilityModel" ProbabilityType)
  probabilityWire <- right (generateCodecs "ProbabilityWire" ProbabilityType)
  unitWire <- right (generateCodecs "UnitWire" UnitType)
  Bytes.writeFile (temporary </> "UnitWire.hs") (Text.encodeUtf8 (Text.pack unitWire))
  Bytes.writeFile (temporary </> "ProbabilityWire.hs") (Text.encodeUtf8 (Text.pack probabilityWire))
  instanceFiles <- right (generateAgenticInstance 0 "Schema.Payload" payload)
  enumFiles <- right (generateAgenticInstance 1 "Schema.Status" status)
  commitmentFiles <- right (generateAgenticInstance 3 "Schema.Commitment"
    (Algebraic "Schema.Commitment" [] [Constructor ("Schema." ++ name) [] | name <- ["Committed","NotCommitted","Unclear"]]))
  sumFiles <- right (generateAgenticInstance 2 "Schema.Choice" choice)
  unless (all (not . Text.isInfixOf "instance Options" . Text.decodeUtf8 . snd) (files instanceFiles ++ files sumFiles))
    (fail "Options generated for a non-enum")
  forM_ [("Schema.Alias",payload),("Schema.List",ListType payload),("Schema.Parameter",Algebraic "Schema.Parameter" [payload] [])] $ \(name,datatype) ->
    case generateAgenticInstance 0 name datatype of
      Left _ -> pure ()
      Right _ -> fail "Generated competing or non-nominal Contract instance"
  forM_ [Algebraic "Schema.Void" [] [], Algebraic "Schema.Bad" []
    [Constructor "Schema.Bad" [(Nothing,BoolType),(Nothing,BoolType)]]] $ \unsupported ->
      case generateAgenticCodec "Rejected" unsupported of
        Left _ -> pure ()
        Right _ -> fail "Unsupported model contract generated code"
  forM_ (files generated ++ files probabilityModel ++ files instanceFiles ++ files enumFiles ++ files sumFiles ++ files commitmentFiles) $ \(relative,bytes) -> do
    let destination = temporary </> relativeName relative
    createDirectoryIfMissing True (takeDirectory destination)
    Bytes.writeFile destination bytes
  Bytes.writeFile (temporary </> "Schema.hs") (Text.encodeUtf8 (Text.unlines
    ["module Schema where", "import Kyyn.Types.Fact (FactId)", "import Agentic.Questions (Probability)",
     "data Status = Open | Done deriving (Eq,Show)",
     "data Commitment = Committed | NotCommitted | Unclear deriving (Eq,Show)",
     "data Choice = Named String | Confidence Probability | Counted { count :: Integer, enabled :: Bool } deriving (Eq,Show)",
     "data Payload = Payload { status :: Status, choices :: [Choice], note :: Maybe String, number :: Integer, identity :: FactId, confidence :: Maybe Probability } deriving (Eq,Show)"]))
  Bytes.writeFile (temporary </> "Main.hs") (Text.encodeUtf8 (Text.unlines
    ["{-# LANGUAGE OverloadedStrings, OverloadedRecordDot, TypeApplications #-}", "module Main where", "import Schema", "import Generated",
     "import Kyyn.Contracts.Schema.Status ()",
     "import Kyyn.Contracts.Schema.Commitment ()",
     "import qualified Agentic.Questions as Q",
     "import qualified Data.Text as Text",
     "import qualified ProbabilityModel as PM", "import qualified ProbabilityWire as PW",
     "import qualified UnitWire as UW",
     "import qualified Kyyn.Runtime.Json as Wire",
     "import Agentic.Contract (options)",
     "import Kyyn.Types.Fact", "import qualified Agentic as A", "import qualified Agentic.Runtime as R",
     "import Kyyn.Contracts.Schema.Payload ()",
     "import Agentic.Runtime (Runtime(..), SystemTwo(..))", "import qualified Agentic.Schema as S",
     "import Control.Monad (unless)",
     "sample = Payload Open [Named \"雪\",Confidence 0.42,Counted 42 True] (Just \"note\") 900719925474099312345 (FactId \"x\") (Just 0.85)",
     "encoded = rootCodec.encode sample",
     "rt :: Runtime (Either String)",
     "rt = (A.runtimeWith (Left . show)) { systemTwo = SystemTwo turn }",
     "turn :: R.Conversation -> Either String A.Turn",
     "turn c = case c.history of",
     "  [] -> if c.outputSchema.shape == rootCodec.schema.shape && c.input == encoded then Right (A.Turn (A.Raw A.Null) (A.Respond (A.Object []))) else Left \"Wrong generated contract\"",
     "  [A.Rejected _ _] -> Right (A.Turn (A.Raw A.Null) (A.Respond encoded))",
     "  _ -> Left \"Unexpected retry history\"",
     "flow :: A.Agentic (Either String) Payload Payload",
     "flow = A.draft \"Draft a value\"",
     "route :: Q.Choice Commitment -> Commitment",
     "route answer | answer.confidence >= 0.7 = answer.chosen | otherwise = Unclear",
     "classify :: A.Agentic (Either String) Text.Text Commitment",
     "classify = A.judge (Q.choice \"Is this a concrete commitment?\") A.>>> A.arr route",
     "main :: IO ()", "main = do",
     "  unless (Wire.decodeWith UW.rootCodec (Wire.encodeWith UW.rootCodec ()) == Right ()) (fail \"Unit codec round trip\")",
     "  mapM_ (\\s -> case Wire.parseValue s >>= Wire.decodeWith UW.rootCodec of Left _ -> pure (); Right _ -> fail \"Invalid unit accepted\") [\"[]\",\"true\",\"{\\\"extra\\\":true}\"]",
     "  mapM_ (\\n -> let p = Q.fromBasisPoints n in do",
     "    unless (Wire.decodeWith PW.rootCodec (Wire.encodeWith PW.rootCodec p) == Right p) (fail \"Probability wire round trip\")",
     "    unless (PM.rootCodec.decode (PM.rootCodec.encode p) == Right p) (fail \"Probability model round trip\")) [0..10000]",
     "  unless (PM.rootCodec.encode 0.85 == A.Number 0.85 && PM.rootCodec.schema == (A.contract :: A.Codec Q.Probability).schema) (fail \"Upstream probability model contract diverged\")",
     "  mapM_ (\\s -> case Wire.parseValue s >>= Wire.decodeWith PW.rootCodec of Left _ -> pure (); Right _ -> fail \"Invalid stored probability accepted\") [\"\\\"-1\\\"\",\"\\\"10001\\\"\",\"\\\"08500\\\"\",\"\\\"0.85\\\"\",\"0.85\"]",
     "  mapM_ (\\v -> unless (either (const Nothing) Just (PM.rootCodec.decode v) == either (const Nothing) Just ((A.contract :: A.Codec Q.Probability).decode v)) (fail \"Upstream model probability decode diverged\")) [A.Number 0.12345,A.Number (-1),A.Number 2,A.Integer 1,A.String \"8500\"]",
     "  mapM_ (\\(chosen, confidence, expected) -> unless (route (Q.Choice chosen [] confidence) == expected) (fail \"Three-way routing failed\")) [(Committed,0.7,Committed),(NotCommitted,0.9,NotCommitted),(Unclear,0.9,Unclear),(Committed,0.69,Unclear)]",
     "  let opts = (options @Status).options",
     "  unless (map (.label) opts == [\"Open\",\"Done\"] && map (.value) opts == [Open,Done] && map (.doc) opts == [Nothing,Nothing]) (fail \"Generated enum options differed\")",
     "  unless (Q.decodeAnswers (Q.choice @Status \"State?\") [Q.ChoiceAnswer \"Done\" [(\"Open\",0.1),(\"Done\",0.9)] 0.8] == Right (Q.Choice Done [(Open,0.1),(Done,0.9)] 0.8)) (fail \"Generated choice options failed\")",
     "  unless (Q.decodeAnswers (Q.score @Status \"Position?\") [Q.ScoreAnswer 0.75 [(0,0.25),(1,0.75)] 0.7] == Right (Q.Score 0.75 [(Open,0.25),(Done,0.75)] 0.7)) (fail \"Generated score options failed\")",
     "  unless (rootCodec.decode encoded == Right sample) (fail \"Round trip failed\")",
     "  unless (A.interpret rt flow sample == Right sample) (fail \"Generated-contract draft/retry failed\")",
     "  let absent = sample { note = Nothing }",
     "  unless (rootCodec.decode (rootCodec.encode absent) == Right absent) (fail \"Optional round trip failed\")",
     "  case encoded of",
     "    A.Object fs -> do",
     "      unless (lookup \"number\" fs == Just (A.String \"900719925474099312345\")) (fail \"Integer lost precision\")",
     "      unless (lookup \"identity\" fs == Just (A.String \"x\")) (fail \"FactId is not text\")",
     "      mapM_ (\\v -> case rootCodec.decode (A.Object ((\"number\",v):filter ((/= \"number\") . fst) fs)) of Left _ -> pure (); Right _ -> fail \"Invalid integer accepted\")",
     "        [A.Number 42, A.Null, A.String \"01\", A.String \"+1\"]",
     "    _ -> fail \"Expected record\"",
     "  case rootCodec.schema.shape of",
     "    S.SObject fs -> case [s.shape | S.Field \"number\" s True <- fs] of",
     "      [S.SString Nothing] -> pure ()",
     "      _ -> fail \"Integer model schema disagrees with codec\"",
     "    _ -> fail \"Expected object schema\"",
     "  putStrLn \"Generated Agentic contracts: typed draft/retry, records, sums, options, IDs and exact integers passed.\""]))
  let includes = map ("-i" ++) [temporary,repo </> "vendor/agentic/src",repo </> "guest/kyyn-runtime/src",
        repo </> "shared/kyyn-types/src",repo </> "vendor/json"]
      command binary arguments = (proc binary arguments) { cwd = Just temporary }
      execute process = do
        (statusCode,output,errors) <- readCreateProcessWithExitCode process ""
        unless (statusCode == ExitSuccess) (fail errors)
        pure output
      native = temporary </> "native"
      artifact = temporary </> "guest.comb"
      mhsEnv = ("MHSDIR",toolchain):("MHSCPPHS",toolchain </> "bin/cpphs"):
        filter (\(key,_) -> key `notElem` ["MHSDIR","MHSCPPHS"]) environment
  _ <- execute (command "ghc-9.10.3" (["-v0","-XGHC2021","-XDataKinds","-XDefaultSignatures","-XDeriveAnyClass",
    "-XDerivingVia","-XGADTs","-XLambdaCase","-XOverloadedStrings","-XRankNTypes","-i"] ++ includes ++
    ["-outputdir",temporary </> "objects","Main.hs","-o",native]))
  _ <- execute ((command (toolchain </> "bin/mhs") (["-a","-i"] ++ includes ++
    ["-i" ++ toolchain </> "lib","Main.hs","-o" ++ artifact])) { env = Just mhsEnv })
  nativeOutput <- execute (command native [])
  guestOutput <- execute (command (toolchain </> "bin/mhseval") ["+RTS","-r" ++ artifact,"-RTS"])
  unless (nativeOutput == guestOutput) (fail "GHC/MicroHs results disagree")
  putStr nativeOutput

right :: Show e => Either e a -> IO a
right = either (fail . show) pure

-- Apply upstream's Cabal-only record defaults to staged sources, not to json.
stageAgentic :: FilePath -> FilePath -> IO ()
stageAgentic source target = do
  createDirectoryIfMissing True target
  entries <- listDirectory source
  forM_ entries $ \name -> do
    let from = source </> name
        to = target </> name
    directory <- doesDirectoryExist from
    if directory then stageAgentic from to else do
      bytes <- Bytes.readFile from
      Bytes.writeFile to ("{-# LANGUAGE NoFieldSelectors, OverloadedRecordDot, DuplicateRecordFields #-}\n" <> bytes)
