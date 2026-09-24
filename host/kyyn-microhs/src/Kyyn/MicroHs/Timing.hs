module Kyyn.MicroHs.Timing (withTimingIO, timingEnabled, emitTiming) where

import Control.Exception (IOException, finally, catch)
import Data.Word (Word64)
import GHC.Clock (getMonotonicTimeNSec)
import System.Environment (lookupEnv)
import System.IO (hPutStrLn, stderr)
import Text.Printf (printf)

timingEnabled :: IO Bool
timingEnabled = (== Just "1") <$> lookupEnv "KYYN_TIMINGS"

withTimingIO :: String -> String -> IO a -> IO a
withTimingIO step label action = do
  enabled <- timingEnabled
  if not enabled then action else do
    start <- getMonotonicTimeNSec
    action `finally` emitTiming step label start

emitTiming :: String -> String -> Word64 -> IO ()
emitTiming step label start = do
  end <- getMonotonicTimeNSec
  let milliseconds = fromIntegral (end - start) / 1000000 :: Double
  hPutStrLn stderr (printf "[kyyn timing] %s %s %.3fms" step (show label) milliseconds)
    `catch` \(_ :: IOException) -> pure ()
