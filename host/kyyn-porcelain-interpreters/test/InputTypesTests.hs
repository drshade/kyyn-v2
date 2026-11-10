-- Stored-shape scaffolding: compile the emitted declarations with GHC, and reject
-- shapes that cannot be represented faithfully. No old application is supplied.
{-# LANGUAGE OverloadedStrings #-}
module Main (main) where
import Control.Monad (unless, forM_)
import Data.Aeson (Value(..))
import qualified Data.ByteString as Bytes
import Data.Either (isLeft)
import Kyyn.Domain.DataType
import Kyyn.Domain.StoredSnapshot
import Kyyn.Domain.FileTree (files)
import Kyyn.Domain.Path (relativeName)
import Kyyn.Types.Fact
import Kyyn.Porcelain.Protocol.InputTypes
import System.Directory (createDirectoryIfMissing)
import System.FilePath ((</>), takeDirectory)
import System.IO.Temp (withSystemTempDirectory)
import System.Process (readProcessWithExitCode)
import System.Exit (ExitCode(..))

main :: IO ()
main = do
  let text = Scalar TextScalar
      payload = Record [("label",text),("aliases",List text),("optional",Optional (Scalar NaturalScalar)),
        ("status",Union [("Pending",Nothing),("Finished",Just (Record [("notes",text)]))])]
      fact shape = Fact (FactId "one") (RecordedValue (Record [("id",text),("value",shape)]) Null)
      snapshot = StoredSnapshot [("count",RecordedValue (Scalar IntegerScalar) Null),
          ("nothing",RecordedValue (Record []) Null), ("labels",RecordedValue (List text) Null)]
        [("people",[fact payload]),("empty",[])] []
  (tree,warnings) <- right (scaffoldInputTypes "fixture-base" snapshot)
  assert "empty collection omission not reported" (length warnings == 1)
  assert "unexpected partial carrier set" (length (files tree) == 4)
  withSystemTempDirectory "kyyn-input-types" $ \directory -> do
    forM_ (files tree) $ \(path,bytes) -> do
      let destination = directory </> relativeName path
      createDirectoryIfMissing True (takeDirectory destination)
      Bytes.writeFile destination bytes
    (exit,output,errors) <- readProcessWithExitCode "cabal"
      (["exec","--","ghc","-fno-code","-Wall","-Werror","-package","kyyn-sdk","-i" ++ directory,
        "-outputdir",directory] ++ [directory </> relativeName path | (path,_) <- files tree]) ""
    assert ("Generated declarations do not compile: " ++ output ++ errors) (exit == ExitSuccess)
  let reject label shape = assert label (isLeft (scaffoldInputTypes "base" (StoredSnapshot [] [("items",[fact shape])] [])))
  reject "illegal field silently renamed" (Record [("type",text)])
  reject "unrepresentable single union invented" (Union [("Only",Nothing)])
  reject "illegal constructor silently renamed" (Union [("lowercase",Nothing),("Other",Nothing)])
  reject "nested constructor collision accepted" (Record
    [("first",Union [("Yes",Nothing),("No",Nothing)]),("second",Union [("Yes",Nothing),("No",Nothing)])])
  assert "heterogeneous members guessed from first value" (isLeft (scaffoldInputTypes "base"
    (StoredSnapshot [] [("items",[fact payload,fact text])] [])))
  putStrLn "Stored input declarations compile and unsupported shapes are diagnosed"
assert :: String -> Bool -> IO ()
assert message condition = unless condition (fail message)
right :: Show e => Either e a -> IO a
right = either (fail . show) pure
