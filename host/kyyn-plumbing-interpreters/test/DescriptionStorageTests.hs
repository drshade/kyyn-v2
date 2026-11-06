-- Descriptor persistence preserves resolved identity, fields, annotations and
-- metadata; references cannot introduce cycles and fingerprints are rechecked.
{-# LANGUAGE OverloadedStrings #-}
module Main (main) where

import Control.Monad (unless, forM_)
import Data.Aeson (Value(..), object, (.=))
import qualified Data.Aeson.KeyMap as Keys
import Data.Aeson.Types (parseEither)
import Data.Either (isLeft)
import Effectful (runPureEff)
import qualified Kyyn.Types.Contract as D
import Kyyn.Types.SchemaMetadata
import qualified Kyyn.Domain.Contract as C
import Kyyn.Plumbing.Protocol.Description
import Kyyn.Plumbing.Protocol.EvolutionRecord.Contract
import Kyyn.Plumbing.Capability.DhallHandling
import Kyyn.Plumbing.Interpreter.DhallHandling (runDhallHandling)

main :: IO ()
main = do
  let fixed = D.TypeIdentity "base" "Data.Fixed" "Fixed" [D.TypeIdentity "base" "Data.Fixed" "E2" []]
      amount = D.ScalarDescription fixed (D.DecimalScalar 100) "Data.Fixed.Fixed" [("resolution","100")]
      text = D.ScalarDescription (D.TypeIdentity "text" "Data.Text.Internal" "Text" []) D.TextScalar "Text" []
      field name inner = D.FieldDescription name "field documentation" inner
      choice = D.NamedDescription (D.TypeIdentity "test" "Schema" "Choice" []) (D.SumDescription
        [D.CaseDescription "None" "no amount" D.PositionalFields [],
         D.CaseDescription "Amount" "an amount" D.PositionalFields [field "_1" amount]])
      description = D.NamedDescription (D.TypeIdentity "test" "Schema" "Root" [])
        (D.RecordDescription "Root" D.NamedFields
          [field "title" text,field "values" (D.DocumentedDescription "values" (D.ListDescription
            (D.OptionalDescription (D.CheckedDescription "business rule" choice))))])
      metadata = SchemaMetadata [RoleDecl "label" "root title" Title] [FieldRole "Schema.Root" "title" "label"] []
  forM_ [D.UnitDescription, amount, choice, description] $ \selected -> do
    let value = descriptionValue selected
    source <- right (runPureEff (runDhallHandling (encodeValue descriptionShape value)))
    decoded <- right (runPureEff (runDhallHandling (decodeValue descriptionShape source)))
    restored <- right (parseEither parseDescription decoded)
    unless (restored == selected) (fail "Description changed in Dhall round trip")
    binary <- right (runPureEff (runDhallHandling (encodeBinaryValue descriptionShape value)))
    decodedBinary <- right (runPureEff (runDhallHandling (decodeBinaryValue descriptionShape binary)))
    restoredBinary <- right (parseEither parseDescription decodedBinary)
    unless (restoredBinary == selected) (fail "Description changed in binary round trip")
  contract <- right (C.checkContract description metadata >>= C.checkRootLayout)
  source <- right (runPureEff (runDhallHandling (encodeValue snapshotShape (snapshotValue contract))))
  decoded <- right (runPureEff (runDhallHandling (decodeValue snapshotShape source)))
  restored <- right (parseEither restoreSnapshot decoded) >>= right
  unless (restored == contract) (fail "Stored contract changed")
  case decoded of
    Object fields -> do
      checked <- right (parseEither restoreSnapshot (Object (Keys.insert "fingerprint" (String "wrong") fields)))
      unless (isLeft checked) (fail "Forged contract identity accepted")
    _ -> fail "Expected contract object"
  forM_ ["0","-1","01"] $ \index ->
    unless (isLeft (parseEither parseDescription (object
      ["types" .= ([] :: [Value]), "nodes" .= [object ["tag" .= ("List" :: String), "value" .= (index :: String)]]])))
      (fail "Cyclic, negative or noncanonical description reference accepted")
  putStrLn "Descriptor storage and identity checks passed."
  where
    right :: Show e => Either e a -> IO a
    right = either (fail . show) pure
