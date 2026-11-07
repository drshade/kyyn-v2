-- Exact scalar Dhall projections: canonical values, semantic rejection in both
-- directions, and unrestricted inferred Naturals. No guest process is exercised.
{-# LANGUAGE OverloadedStrings #-}
module Main (main) where

import Control.Monad (forM_, unless)
import Data.Aeson (Value(..))
import Data.Either (isLeft)
import Data.Text (Text)
import qualified Data.Text as Text
import Effectful (runPureEff)
import Kyyn.Domain.DataType (Shape(..), ScalarKind(..))
import qualified Kyyn.Types.Contract as D
import Kyyn.Plumbing.Capability.DhallHandling
import Kyyn.Plumbing.Interpreter.DhallHandling (runDhallHandling)

main :: IO ()
main = do
  forM_ [(D.DecimalScalar 100,"-12.34"),
    (D.DecimalScalar 100,"123456789012345678901234567890123456789.01"),
    (D.DecimalScalar 100,"0"), (D.NaturalScalar,"10001"),
    (D.IntScalar (-128) 127,"-128"), (D.IntScalar (-128) 127,"127"),
    (D.DateScalar,"2026-11-06"), (D.InstantScalar,"2026-11-06T12:34:56.123456Z"),
    (D.FactIdScalar,"fact-雪")] $ \(kind,text) -> do
      let shape = Scalar (ExactScalar kind)
          value = String text
      source <- right (runPureEff (runDhallHandling (encodeValue shape value)))
      decoded <- right (runPureEff (runDhallHandling (decodeValue shape source)))
      unless (decoded == value) (fail ("Scalar changed during storage: " ++ show kind))
      binary <- right (runPureEff (runDhallHandling (encodeBinaryValue shape value)))
      decodedBinary <- right (runPureEff (runDhallHandling (decodeBinaryValue shape binary)))
      unless (decodedBinary == value) (fail "Binary scalar round trip changed")
  forM_ [(D.DecimalScalar 100,"12.345"),(D.DecimalScalar 100,"1e2"),
    (D.DecimalScalar 100,"-0"),(D.NaturalScalar,"-1"),
    (D.IntScalar (-128) 127,"128"),(D.IntScalar (-128) 127,"-129"),
    (D.DateScalar,"2026-02-30"),(D.InstantScalar,"2026-11-06T12:34:56+01:00"),
    (D.FactIdScalar,"")] $ \(kind,text) -> do
      let shape = Scalar (ExactScalar kind)
      unless (isLeft (runPureEff (runDhallHandling (encodeValue shape (String text)))))
        (fail ("Invalid scalar accepted: " ++ show (kind,text)))
  forM_ [(D.DecimalScalar 100,"\"12.345\""), (D.DateScalar,"\"2026-02-30\""),
    (D.InstantScalar,"\"not an instant\""),(D.FactIdScalar,"\"\""),
    (D.IntScalar (-128) 127,"+128")] $ \(kind,source) ->
      unless (isLeft (runPureEff (runDhallHandling (decodeValue (Scalar (ExactScalar kind)) source))))
        (fail ("Invalid stored scalar accepted: " ++ show kind))
  (_,inferred) <- right (runPureEff (runDhallHandling (inferValue "10001")))
  unless (inferred == String "10001") (fail "Natural incorrectly treated as Probability")
  let natural = Scalar (ExactScalar D.NaturalScalar)
  naturalType <- pure (runPureEff (runDhallHandling (renderType natural)))
  unless (Text.strip naturalType == ("Natural" :: Text)) (fail "Natural projection is not Natural")
  putStrLn "Exact scalar storage and rejection checks passed."
  where right = either (fail . show) pure
