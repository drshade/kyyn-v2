{-# LANGUAGE TypeApplications #-}
module Main (main) where

import Control.Exception (AsyncException(..), IOException, displayException, try, tryJust)
import Control.Monad (when)
import Data.Aeson (Value(Null), encode)
import qualified Data.ByteString.Lazy.Char8 as Bytes
import Kyyn.Composition (execute)
import Kyyn.Domain.Diagnostic (errorDiagnostic)
import qualified Kyyn.Surfaces.Cli as Cli
import Kyyn.Surfaces.Result
import Options.Applicative (customExecParser)
import System.Exit (ExitCode(..), exitWith)
import System.IO (hPutStrLn, stderr)

main :: IO ()
main = do
  invocation@(Cli.Invocation _ output command) <- customExecParser Cli.cliPrefs Cli.cliInfo
  mapM_ (hPutStrLn stderr) (Cli.progressMessage command)
  result <- tryJust (\exception -> case exception of UserInterrupt -> Just (); _ -> Nothing)
    (try @IOException (execute invocation))
  let response = case result of
        Left _ -> interruption (case command of Cli.Evolution (Cli.AcceptEvolution identity) -> Just identity; _ -> Nothing)
        Right (Left exception) -> Response Failed Null []
          [errorDiagnostic "host.io" (displayException exception)]
        Right (Right value) -> value
  case output of
    Cli.Json -> Bytes.putStrLn (encode (responseJson response))
    Cli.Human -> case response of
      Response _ _ messages diagnostics -> do
        mapM_ putStrLn messages
        mapM_ (hPutStrLn stderr . diagnosticText) diagnostics
  when (exitStatus response /= 0) (exitWith (ExitFailure (exitStatus response)))
