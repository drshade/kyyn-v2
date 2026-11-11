-- Provider JSON and timestamp conformance: precision, duplicate policy, Unicode,
-- full-input parsing, stable canonical records and strict calendar/offset rules.
module Main where

import Control.Monad (forM_, unless)
import Data.Either (isLeft)
import Data.Ratio ((%))
import qualified MicrosoftGraph.Json as Graph
import qualified Salesforce.Json as Salesforce
import qualified GitHub.Json as GitHub
import MicrosoftGraph.Timestamp (timestamp, daysBefore)

main :: IO ()
main = do
  check "Graph first duplicate wins" $
    (Graph.parse "{\"x\":\"first\",\"x\":null}" >>= Graph.member "x" >>= Graph.text) == Right "first"
  check "GitHub first duplicate wins" $
    (GitHub.parse "{\"x\":\"first\",\"x\":null}" >>= GitHub.field "x" >>= GitHub.text) == Right "first"
  forM_ ["{\"x\":1,\"x\":2}","{\"x\":{\"a\":1,\"a\":2}}"] $ \input ->
    check "Salesforce duplicate accepted" (isLeft (Salesforce.parse input))
  forM_ ["{} trailing", "\"\\ud800\"", "[1,]"] $ \input -> do
    check "Graph malformed response accepted" (isLeft (Graph.parse input))
    check "Salesforce malformed response accepted" (isLeft (Salesforce.parse input))
    check "GitHub malformed response accepted" (isLeft (GitHub.parse input))
  check "Unicode pair lost" ((Graph.parse "\"\\ud83d\\ude00\"" >>= Graph.text) == Right "😀")
  check "Large GitHub integer rounded" ((GitHub.parse "9007199254740993" >>= GitHub.integer) == Right 9007199254740993)
  forM_ ["-1","1.5","9223372036854775808"] $ \input -> do
    check "Graph invalid count accepted" (isLeft (Graph.parse input >>= Graph.integer))
    check "Salesforce invalid count accepted" (isLeft (Salesforce.parse input >>= Salesforce.integer))
  check "Salesforce precision/order changed" $
    (fmap Salesforce.canonical (Salesforce.parse "{\"z\":1.2300,\"b\":9007199254740993,\"a\":1e-20,\"c\":-2,\"s\":\"é\\n\"}")) ==
      Right "{\"a\":0.00000000000000000001,\"b\":9007199254740993,\"c\":-2,\"s\":\"é\\n\",\"z\":1.23}"
  check "Timestamp epoch changed" (timestamp "0001-01-01T00:00:00Z" == Right 0)
  check "Timestamp precision lost" (timestamp "0001-01-01T00:00:00.000000000000000001Z" == Right (1 % (10^(18 :: Int))))
  check "Offset changed instant" (timestamp "2024-02-29T02:00:00+02:00" == timestamp "2024-02-29T00:00:00Z")
  check "Negative zero zone refused" (timestamp "2024-02-29T00:00:00-00:00" == timestamp "2024-02-29T00:00:00Z")
  forM_ ["0000-01-01T00:00:00Z","1900-02-29T00:00:00Z","2026-04-31T00:00:00Z",
      "2026-01-01T24:00:00Z","2026-01-01T00:00:60Z","2026-01-01T00:00:00+24:00",
      "2026-01-01T00:00:00+01:60","2026-01-01T00:00:00.Z","2026-01-01T00:00:00Z "] $ \input ->
    check "Invalid timestamp accepted" (isLeft (timestamp input))
  check "Leap-day backfill changed" (daysBefore 1 "2000-03-01T12:34:56.123456789012345Z" == Right "2000-02-29T12:34:56.123456789012345Z")
  check "Non-leap century changed" (daysBefore 1 "1900-03-01T00:00:00Z" == Right "1900-02-28T00:00:00Z")
  check "Backfill before year one accepted" (isLeft (daysBefore (10^(20 :: Int)) "2026-01-01T00:00:00Z"))
  check "Negative backfill accepted" (isLeft (daysBefore (-1) "2026-01-01T00:00:00Z"))
  check "Non-UTC backfill accepted" (isLeft (daysBefore 1 "2026-01-01T00:00:00+00:00"))
  putStrLn "Provider JSON precision, duplicate/Unicode rules and timestamp conformance passed."
  where check label condition = unless condition (fail label)
