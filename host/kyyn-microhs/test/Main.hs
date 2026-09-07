module Main where

import Control.Monad (unless, forM_)
import Data.List (isInfixOf)
import qualified Data.Aeson as A
import qualified Data.ByteString.Lazy as B
import qualified Data.Text as T
import qualified Data.Text.Encoding as T
import Kyyn.MicroHs.Inspection (inspectDataType)
import Kyyn.Plumbing.Capability.SchemaInspection.Codecs (generateCodecs)
import System.Directory (createDirectoryIfMissing)
import System.Environment (getEnv)
import System.Exit (ExitCode(..))
import System.FilePath ((</>))
import System.Process (readProcessWithExitCode)

main :: IO ()
main = do
  repo <- getEnv "KYYN_TEST_ROOT"
  let compiler = repo </> "vendor/MicroHs"
      fixtures = repo </> "tests/integration/codecs"
      output = repo </> ".build/codecs"
      guest = repo </> "guest/kyyn-runtime/src"
      json = repo </> "vendor/json"
  createDirectoryIfMissing True output
  forM_ [("FunctionField", "function-valued"), ("Recursive", "recursive"),
         ("IllTyped", "IllTyped.hs"), ("Hidden", "opaque"), ("Positional", "positional")] $ \(name, expected) -> do
    result <- inspectDataType compiler [fixtures] (name ++ ".Root")
    case result >>= generateCodecs of
      Left message | expected `isInfixOf` message -> pure ()
      other -> fail (name ++ ": expected rejection containing " ++ expected ++ ", received " ++ show other)
  forM_ ["Model.Root", "Model.RootAlias"] $ \selected -> do
    inspected <- inspectDataType compiler [fixtures] selected >>= either fail pure
    generated <- either fail pure (generateCodecs inspected)
    writeFile (output </> "KyynGeneratedCodec.hs") generated
    (compiled, _, errors) <- readProcessWithExitCode (compiler </> "bin/mhs")
      ["-i" ++ concatPaths [fixtures, output, guest, json], fixtures </> "RoundTrip.hs", "-o" ++ output </> "roundtrip"] ""
    unless (compiled == ExitSuccess) (fail errors)
    let invoke input = do
          (status, actual, diagnostics) <- readProcessWithExitCode (output </> "roundtrip") [] (input ++ "\n")
          unless (status == ExitSuccess) (fail diagnostics)
          decoded <- either fail pure (A.eitherDecode (utf8 actual))
          pure (decoded, diagnostics)
        success input expected = do
          (actual, errors') <- invoke input
          unless (actual == expected && null errors') (fail (show (actual, errors')))
        rejection input = do
          (actual, diagnostics) <- invoke input
          unless (actual == A.object ["error" A..= True] && not (null diagnostics))
            (fail ("expected diagnostic rejection, received " ++ show actual))
        value = A.object ["todos" A..= [A.object ["contents" A..= A.object
          ["name" A..= ("München 日本語 🦋\n\0" :: String), "status" A..= tag "Blocked" (Just (A.String "awaiting review"))
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

tag :: String -> Maybe A.Value -> A.Value
tag name value = A.object (["tag" A..= name] ++ maybe [] (\v -> ["value" A..= v]) value)

utf8 :: String -> B.ByteString
utf8 = B.fromStrict . T.encodeUtf8 . T.pack

encode :: A.Value -> String
encode = T.unpack . T.decodeUtf8 . B.toStrict . A.encode

concatPaths :: [FilePath] -> String
concatPaths [] = ""
concatPaths [p] = p
concatPaths (p:ps) = p ++ ":" ++ concatPaths ps
