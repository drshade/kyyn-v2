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
import System.Directory (createDirectoryIfMissing)
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
  let status = Algebraic "Schema.Status" [] [Constructor "Schema.Open" [],Constructor "Schema.Done" []]
      choice = Algebraic "Schema.Choice" [] [Constructor "Schema.Named" [(Nothing,StringType)],
        Constructor "Schema.Counted" [(Just "count",IntegerType),(Just "enabled",BoolType)]]
      payload = Algebraic "Schema.Payload" [] [Constructor "Schema.Payload"
        [(Just "status",status),(Just "choices",ListType choice),(Just "note",OptionalType StringType),
         (Just "number",IntegerType),(Just "identity",sdkFactIdType)]]
  generated <- right (generateAgenticCodec "Generated" payload)
  instanceFiles <- right (generateAgenticInstance 0 "Schema.Payload" payload)
  forM_ [("Schema.Alias",payload),("Schema.List",ListType payload),("Schema.Parameter",Algebraic "Schema.Parameter" [payload] [])] $ \(name,datatype) ->
    case generateAgenticInstance 0 name datatype of
      Left _ -> pure ()
      Right _ -> fail "Generated competing or non-nominal Contract instance"
  forM_ [Algebraic "Schema.Void" [] [], Algebraic "Schema.Bad" []
    [Constructor "Schema.Bad" [(Nothing,BoolType),(Nothing,BoolType)]]] $ \unsupported ->
      case generateAgenticCodec "Rejected" unsupported of
        Left _ -> pure ()
        Right _ -> fail "Unsupported model contract generated code"
  forM_ (files generated ++ files instanceFiles) $ \(relative,bytes) -> do
    let destination = temporary </> relativeName relative
    createDirectoryIfMissing True (takeDirectory destination)
    Bytes.writeFile destination bytes
  Bytes.writeFile (temporary </> "Schema.hs") (Text.encodeUtf8 (Text.unlines
    ["module Schema where", "import Kyyn.Types.Fact (FactId)",
     "data Status = Open | Done deriving (Eq,Show)",
     "data Choice = Named String | Counted { count :: Integer, enabled :: Bool } deriving (Eq,Show)",
     "data Payload = Payload { status :: Status, choices :: [Choice], note :: Maybe String, number :: Integer, identity :: FactId } deriving (Eq,Show)"]))
  Bytes.writeFile (temporary </> "Main.hs") (Text.encodeUtf8 (Text.unlines
    ["{-# LANGUAGE OverloadedStrings #-}", "module Main where", "import Schema", "import Generated",
     "import Kyyn.Types.Fact", "import qualified Agentic as A", "import qualified Agentic.Runtime as R",
     "import Kyyn.Contracts.Schema.Payload ()",
     "import Agentic.Runtime (Runtime(..), SystemTwo(..))", "import qualified Agentic.Schema as S",
     "import Control.Monad (unless)",
     "sample = Payload Open [Named \"雪\",Counted 42 True] (Just \"note\") 900719925474099312345 (FactId \"x\")",
     "encoded = A.encode rootCodec sample",
     "rt :: Runtime (Either String)",
     "rt = (A.runtimeWith (Left . show)) { systemTwo = SystemTwo turn }",
     "turn c = case R.history c of",
     "  [] -> if S.shape (R.output c) == S.shape (A.codecSchema rootCodec) && R.state c == encoded then Right (A.Turn (A.Raw A.Null) (A.Respond (A.Object []))) else Left \"Wrong generated contract\"",
     "  [A.Rejected _ _] -> Right (A.Turn (A.Raw A.Null) (A.Respond encoded))",
     "  _ -> Left \"Unexpected retry history\"",
     "flow :: A.Agentic (Either String) Payload Payload",
     "flow = A.draft \"Draft a value\"",
     "main :: IO ()", "main = do",
     "  unless (A.decode rootCodec encoded == Right sample) (fail \"Round trip failed\")",
     "  unless (A.interpret rt flow sample == Right sample) (fail \"Generated-contract draft/retry failed\")",
     "  let absent = sample { note = Nothing }",
     "  unless (A.decode rootCodec (A.encode rootCodec absent) == Right absent) (fail \"Optional round trip failed\")",
     "  case encoded of",
     "    A.Object fs -> do",
     "      unless (lookup \"number\" fs == Just (A.String \"900719925474099312345\")) (fail \"Integer lost precision\")",
     "      unless (lookup \"identity\" fs == Just (A.String \"x\")) (fail \"FactId is not text\")",
     "      mapM_ (\\v -> case A.decode rootCodec (A.Object ((\"number\",v):filter ((/= \"number\") . fst) fs)) of Left _ -> pure (); Right _ -> fail \"Invalid integer accepted\")",
     "        [A.Number 42, A.Null, A.String \"01\", A.String \"+1\"]",
     "    _ -> fail \"Expected record\"",
     "  case S.shape (A.codecSchema rootCodec) of",
     "    S.SObject fs -> case [S.shape s | S.Field \"number\" s True <- fs] of",
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
