module Main where

import Control.Monad (unless, forM_)
import Data.List (isInfixOf)
import qualified Data.Aeson as A
import qualified Data.ByteString.Lazy as B
import qualified Data.ByteString as Bytes
import qualified Data.Text as T
import qualified Data.Text.Encoding as T
import Kyyn.MicroHs.Inspection (InspectionError(..), inspectDataType)
import Kyyn.Plumbing.Capability.SchemaInspection.Codecs (generateCodecs)
import Kyyn.Plumbing.Capability.ProcessExecution
import Kyyn.Plumbing.Capability.GuestCompilation
import Kyyn.Plumbing.Capability.GuestExecution (executeCompiled)
import Kyyn.Domain.Path
import Kyyn.MicroHs.Toolchain (GuestToolchain(..))
import Kyyn.MicroHs.Interpreter.GuestCompilation (runGuestCompilation)
import Kyyn.MicroHs.Interpreter.GuestExecution (runGuestExecution)
import Kyyn.Plumbing.Interpreter.Failure (runFailure)
import Kyyn.Plumbing.Interpreter.FileSystem (runFileSystemIO)
import Kyyn.Plumbing.Interpreter.ProcessExecution (runProcessExecutionIO)
import Effectful (runEff)
import System.Directory (listDirectory)
import System.Environment (getEnv)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import CompilationTests (testCompilation)

main :: IO ()
main = withSystemTempDirectory "kyyn-codecs" $ \temporary -> do
  repo <- getEnv "KYYN_TEST_ROOT"
  compiler <- getEnv "KYYN_TEST_TOOLCHAIN"
  temporaryScope <- either fail pure (directoryScope temporary)
  let fixtures = repo </> "tests/integration/codecs"
      guest = repo </> "guest/kyyn-runtime/src"
      json = repo </> "vendor/json"
  toolchain <- GuestToolchain <$> either fail pure (directoryScope compiler)
  testEmptyRoot temporaryScope toolchain compiler fixtures guest json
  testCompilation temporaryScope toolchain
  let compile sources = runEff . runFailure . runProcessExecutionIO . runFileSystemIO temporaryScope . runGuestCompilation toolchain Nothing $
        compileGuest sources
  forM_ [("FunctionField", "function-valued"), ("Recursive", "recursive"),
         ("IllTyped", "IllTyped.hs"), ("Hidden", "opaque"), ("Positional", "positional"),
         ("AbsentModule", "not found"), ("TupleField", "tuples"),
         ("CharField", "unsupported"), ("DoubleField", "unsupported"),
         ("NaturalField", "opaque")] $ \(name, expected) -> do
    result <- inspectDataType compiler [fixtures] (name ++ ".Root")
    case either (Left . show) (Right . fst) result >>= generateCodecs "KyynGeneratedCodec" of
      Left message | expected `isInfixOf` message -> pure ()
      other -> fail (name ++ ": expected rejection containing " ++ expected ++ ", received " ++ show other)
  absentType <- inspectDataType compiler [fixtures] "Model.AbsentType"
  case absentType of
    Left (CompilerError _) -> pure ()
    other -> fail ("expected missing-type compiler diagnostic: " ++ show other)
  forM_ ["Model.Root", "Model.RootAlias"] $ \selected -> do
    (inspected,_) <- inspectDataType compiler [fixtures] selected >>= either (fail . show) pure
    generated <- either fail pure (generateCodecs "KyynGeneratedCodec" inspected)
    second <- either fail pure (generateCodecs "KyynSecondCodec" inspected)
    files <- mapM (\(base, path) -> (,) (checkedPath path) <$> Bytes.readFile (base </> path))
      [(fixtures, "Model.hs"), (fixtures, "RoundTrip.hs"), (guest, "Kyyn/Runtime/Json.hs"),
       (json, "Text/JSON/Types.hs"), (json, "Text/JSON/String.hs")]
    sources <- either fail pure (guestSources (checkedPath "RoundTrip.hs")
      (files ++ [(checkedPath "KyynGeneratedCodec.hs", B.toStrict (utf8 generated)),
                 (checkedPath "KyynSecondCodec.hs", B.toStrict (utf8 second))]))
    compiled <- compile sources >>= either (fail . show) (either (fail . show) pure)
    remaining <- listDirectory temporary
    unless (null remaining) (fail "compilation leaked its temporary sources")
    let invoke input = do
          outcome <- runEff . runFailure . runProcessExecutionIO . runFileSystemIO temporaryScope . runGuestExecution toolchain $
            executeCompiled compiled (B.toStrict (utf8 (input ++ "\n")))
          (actual, ProcessExit status diagnostics) <- either (fail . show) pure outcome
          unless (status == 0) (fail (show diagnostics))
          decoded <- either fail pure (A.eitherDecodeStrict actual)
          pure (decoded, diagnostics)
        success input expected = do
          (actual, errors') <- invoke input
          unless (actual == expected && Bytes.null errors') (fail (show (actual, errors')))
        rejection input = do
          (actual, diagnostics) <- invoke input
          unless (actual == A.object ["error" A..= True] && not (Bytes.null diagnostics))
            (fail ("expected diagnostic rejection, received " ++ show actual))
        value = A.object ["todos" A..= [A.object ["contents" A..= A.object
          ["name" A..= ("München 日本語 🦋\n\0" :: String), "identity" A..= tag "Wrapped" (Just (A.String "todo-001"))
          ,"decision" A..= tag "Right" (Just (A.String "42"))
          ,"status" A..= tag "Blocked" (Just (A.String "awaiting review"))
          ,"note" A..= tag "Some" (Just (tag "None" Nothing))
          ,"budget" A..= ("123456789012345678901234567890" :: String)
          ,"choice" A..= tag "Detailed" (Just (A.object ["title" A..= ("detail" :: String), "count" A..= ("-42" :: String)]))]]]
          ,"enabled" A..= True]
    success (encode value) value
    success "{\"todos\":[],\"enabled\":true,\"enabled\":false}" (A.object ["todos" A..= ([] :: [A.Value]), "enabled" A..= True])
    forM_ ["{", "{}", "{\"todos\":[],\"enabled\":1}",
      "{\"todos\":[],\"enabled\":true,\"unexpected\":true}",
      "{\"todos\":[],\"enabled\":true} trailing"] rejection
    let replace a b = T.unpack . T.replace a b . T.pack $ encode value
    forM_ [replace "Blocked" "Unknown", replace "awaiting review" "\\ud83e\\udd8b",
      replace "\"123456789012345678901234567890\"" "123",
      replace "123456789012345678901234567890" "01",
      replace "\"Some\"" "\"None\""] rejection
  putStrLn "Compiler-inspected ADT codecs: real MicroHs round trips and rejection cases passed."

testEmptyRoot :: DirectoryScope -> GuestToolchain -> FilePath -> FilePath -> FilePath -> FilePath -> IO ()
testEmptyRoot temporary toolchain compiler fixtures guest json = do
  (inspected,_) <- inspectDataType compiler [fixtures] "Empty.Root" >>= either (fail . show) pure
  generated <- either fail pure (generateCodecs "KyynGeneratedCodec" inspected)
  second <- either fail pure (generateCodecs "KyynSecondCodec" inspected)
  captured <- mapM (\(base, path) -> (,) (checkedPath path) <$> Bytes.readFile (base </> path))
    [(fixtures,"Empty.hs"), (fixtures,"RoundTrip.hs"), (guest,"Kyyn/Runtime/Json.hs"),
     (json,"Text/JSON/Types.hs"), (json,"Text/JSON/String.hs")]
  sources <- either fail pure (guestSources (checkedPath "RoundTrip.hs")
    (captured ++ [(checkedPath "KyynGeneratedCodec.hs", B.toStrict (utf8 generated)),
                    (checkedPath "KyynSecondCodec.hs", B.toStrict (utf8 second))]))
  compiled <- runEff (runFailure (runProcessExecutionIO (runFileSystemIO temporary
    (runGuestCompilation toolchain Nothing (compileGuest sources))))) >>= either (fail . show) (either (fail . show) pure)
  forM_ [("{}", A.object [], True), ("{\"extra\":true}", A.object ["error" A..= True], False),
    ("{\"tag\":\"Root\"}", A.object ["error" A..= True], False)] $ \(input,expected,valid) -> do
      result <- runEff (runFailure (runProcessExecutionIO (runFileSystemIO temporary
        (runGuestExecution toolchain (executeCompiled compiled (B.toStrict (utf8 (input ++ "\n"))))))))
      (output,ProcessExit status diagnostics) <- either (fail . show) pure result
      actual <- either fail pure (A.eitherDecodeStrict output)
      unless (status == 0 && actual == expected && Bytes.null diagnostics == valid)
        (fail ("Empty root codec mismatch: " ++ show result))
  putStrLn "Empty root: compiler-inspected MicroHs codecs round-trip {} and reject extra/tagged fields."

tag :: String -> Maybe A.Value -> A.Value
tag name value = A.object (["tag" A..= name] ++ maybe [] (\v -> ["value" A..= v]) value)

utf8 :: String -> B.ByteString
utf8 = B.fromStrict . T.encodeUtf8 . T.pack

encode :: A.Value -> String
encode = T.unpack . T.decodeUtf8 . B.toStrict . A.encode

checkedPath :: FilePath -> RelativePath
checkedPath = either error id . relativePath
