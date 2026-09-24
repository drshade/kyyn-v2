{-# LANGUAGE GADTs #-}
module Kyyn.Plumbing.Capability.Judgement.Jev (jevModel, requestBody, decodeResponse) where

import Control.Monad (unless)
import Data.Aeson (Value, object, (.=), (.:), withObject)
import Data.Aeson.Types (Parser, parseEither)
import qualified Data.Aeson.Key as Key
import qualified Data.Aeson.KeyMap as Keys
import Data.List (sort)
import Kyyn.Types.Judgement

jevModel :: String
jevModel = "jev-1.13.0"

requestBody :: JudgementRequest a -> Value
requestBody request = case request of
  YesNoRequest context question -> body context (object ["type" .= ("noul" :: String), "instructions" .= question])
  ChoiceRequest context question options -> body context (object
    ["type" .= ("choice" :: String), "instructions" .= question,
     "criteria" .= object [Key.fromString label .= description | (label,description) <- options]])
  ScaleRequest context question descriptions -> body context (object
    ["type" .= ("score" :: String), "instructions" .= question, "criteria" .= descriptions])
  where
    body (Context context) question = object
      ["model" .= jevModel, "state" .= context, "questions" .= object ["judgement" .= question]]

decodeResponse :: JudgementRequest a -> Value -> Either JudgementFailure (Judged a)
decodeResponse request value = case parseEither (withObject "response" $ \response -> do
  identity <- response .: "model"
  unless (not (null identity)) (fail "Missing model identity")
  answers <- response .: "answers"
  unless (Keys.keys answers == ["judgement"]) (fail "Unexpected answer identities")
  result <- answers .: "judgement" >>= decodeAnswer request
  pure (Judged identity result)) value of
    Left _ -> Left InvalidProviderResponse
    Right result -> Right result

decodeAnswer :: JudgementRequest a -> Value -> Parser a
decodeAnswer request = withObject "answer" $ \answerValue -> do
  kind <- answerValue .: "type" :: Parser String
  case request of
    YesNoRequest _ _ -> do
      unless (kind == ("noul" :: String)) (fail "Incorrect answer kind")
      YesNoAnswer <$> (answerValue .: "noul" >>= probability)
    ChoiceRequest _ _ options -> do
      unless (kind == "choice") (fail "Incorrect answer kind")
      winner <- answerValue .: "choice"
      unless (winner `elem` map fst options) (fail "Unknown selected option")
      probabilities <- answerValue .: "probabilities" >>= distribution (map fst options)
      confidence <- answerValue .: "confidence" >>= probability
      pure (ChoiceAnswer winner probabilities confidence)
    ScaleRequest _ _ descriptions -> do
      unless (kind == "score") (fail "Incorrect answer kind")
      value <- answerValue .: "score"
      unless (finite value && value >= 0 && value <= fromIntegral (length descriptions - 1))
        (fail "Score outside supplied scale")
      let labels = map show [0 :: Integer .. toInteger (length descriptions) - 1]
      legend <- answerValue .: "legend"
      unless (sort (map Key.toString (Keys.keys legend)) == sort labels) (fail "Incorrect legend")
      mapM_ (\(label,description) -> do
        actual <- legend .: Key.fromString label
        unless (actual == description) (fail "Incorrect level description")) (zip labels descriptions)
      probabilities <- answerValue .: "probabilities" >>= distribution labels
      confidence <- answerValue .: "confidence" >>= probability
      pure (ScaleAnswer value (zip [0..] (map snd probabilities)) confidence)

distribution :: [String] -> Value -> Parser [(String,Double)]
distribution labels = withObject "distribution" $ \values -> do
  unless (sort (map Key.toString (Keys.keys values)) == sort labels) (fail "Incorrect distribution labels")
  probabilities <- mapM (\label -> do
    value <- values .: Key.fromString label >>= probability
    pure (label,value)) labels
  unless (abs (sum (map snd probabilities) - 1) <= 1e-6) (fail "Distribution does not sum to one")
  pure probabilities

probability :: Double -> Parser Double
probability value
  | finite value && value >= 0 && value <= 1 = pure value
  | otherwise = fail "Invalid probability"

finite :: Double -> Bool
finite value = not (isNaN value || isInfinite value)
