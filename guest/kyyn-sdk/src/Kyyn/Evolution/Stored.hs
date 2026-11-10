{-# LANGUAGE OverloadedStrings, ScopedTypeVariables, TypeApplications, OverloadedRecordDot #-}
-- Internal stored-data representation. Never exposed as an author mutation API.
module Kyyn.Evolution.Stored
  ( StoredSnapshot(..), RecordedValue(..), StoredRecipe(..), Observation(..)
  , StepOrigin(..), decodeStored, encodeStored, decodeFact, encodeFact, failure
  ) where

import Data.Text (Text)
import qualified Data.Text as Text
import Text.JSON.Types (JSValue(..), fromJSObject, toJSObject, fromJSString, toJSString)
import Kyyn.Contract
import Kyyn.Contract.Wire (toWire, fromWire)
import Kyyn.Types.Fact (Fact(..), FactId(..), parseFactId)
import Kyyn.Types.KnowledgeBase (Recipe)
import Kyyn.Types.Evolution (EvolutionFailure(..), Rationale)
import Kyyn.Types.Diagnostic (errorDiagnostic)
import Kyyn.Types.StoredShape

-- Each recorded fact value includes the full id/value envelope.
data RecordedValue = RecordedValue StoredShape JSValue deriving (Eq, Show)
data StoredRecipe = StoredRecipe Recipe (Maybe Text) RecordedValue deriving (Eq, Show)
data StoredSnapshot = StoredSnapshot
  [(Text,RecordedValue)] [(Text,[Fact RecordedValue])] [Fact StoredRecipe]
  deriving (Eq, Show)
data StepOrigin = Authored | TargetProjection deriving (Eq, Show)
data Observation = Observation StepOrigin Rationale StoredSnapshot StoredSnapshot deriving (Eq, Show)

decodeStored :: forall a. Contract a => RecordedValue -> Either EvolutionFailure a
decodeStored (RecordedValue actual value) = do
  compiled <- either (failure . Text.pack . show) Right (compileContract (contract @a))
  expected <- either failure Right (storedShape compiled.description)
  if canonicalShape actual /= expected then failure "Stored shape does not match selected decoding view"
    else either failure Right (compiled.codec.decode (fromWire value))

encodeStored :: forall a. Contract a => a -> Either EvolutionFailure RecordedValue
encodeStored value = do
  compiled <- either (failure . Text.pack . show) Right (compileContract (contract @a))
  shape <- either failure Right (storedShape compiled.description)
  pure (RecordedValue shape (toWire (compiled.codec.encode value)))

failure :: Text -> Either EvolutionFailure a
failure message = Left (EvolutionFailure [errorDiagnostic "evolution.preparation" message])

encodeFact :: Contract a => Fact a -> Either EvolutionFailure RecordedValue
encodeFact (Fact (FactId name) value) = do
  _ <- either failure Right (parseFactId name)
  RecordedValue shape encoded <- encodeStored value
  pure (RecordedValue (StoredRecord [("id",StoredText),("value",shape)])
    (JSObject (toJSObject [("id",JSString (toJSString (Text.unpack name))),("value",encoded)])))

decodeFact :: Contract a => RecordedValue -> Either EvolutionFailure (Fact a)
decodeFact (RecordedValue shape (JSObject object))
  | StoredRecord [("id",StoredText),("value",payload)] <- canonicalShape shape
  , fields <- fromJSObject object
  , length fields == 2
  , Just (JSString rawId) <- lookup "id" fields
  , Just value <- lookup "value" fields = do
      identity <- either failure Right (parseFactId (Text.pack (fromJSString rawId)))
      Fact identity <$> decodeStored (RecordedValue payload value)
decodeFact _ = failure "Invalid stored fact envelope"
