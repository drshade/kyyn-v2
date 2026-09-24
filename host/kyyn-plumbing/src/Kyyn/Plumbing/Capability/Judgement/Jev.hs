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

requestBody :: JudgementRequest -> Value
requestBody (JudgementRequest (Context context) questions) = object
  ["model" .= jevModel, "state" .= context,
   "questions" .= object [Key.fromString label .= questionValue question | (label,question) <- named questions]]

questionValue :: QuestionSpec -> Value
questionValue request = case request of
  YesNoRequest question yes no -> object
    ["type" .= ("noul" :: String), "instructions" .= question,
     "criteria" .= object ["true" .= yes, "false" .= no]]
  ChoiceRequest question options -> object
    ["type" .= ("choice" :: String), "instructions" .= question,
     "criteria" .= object [Key.fromString label .= description | (label,description) <- options]]
  ScaleRequest question descriptions -> object
    ["type" .= ("score" :: String), "instructions" .= question, "criteria" .= descriptions]

named :: [a] -> [(String,a)]
named = zip ["q" ++ show n | n <- [0 :: Integer ..]]

decodeResponse :: JudgementRequest -> Value -> Either JudgementFailure [JudgementAnswer]
decodeResponse (JudgementRequest _ questions) value = case parseEither (withObject "response" $ \response -> do
  answers <- response .: "answers"
  let entries = named questions
  unless (sort (map Key.toString (Keys.keys answers)) == sort (map fst entries))
    (fail "Unexpected answer identities")
  mapM (\(label,question) -> answers .: Key.fromString label >>= decodeAnswer question) entries) value of
    Left _ -> Left InvalidProviderResponse
    Right result -> Right result

decodeAnswer :: QuestionSpec -> Value -> Parser JudgementAnswer
decodeAnswer request = withObject "answer" $ \answerValue -> do
  kind <- answerValue .: "type" :: Parser String
  case request of
    YesNoRequest _ _ _ -> do
      unless (kind == ("noul" :: String)) (fail "Incorrect answer kind")
      YesNoResult . YesNoAnswer <$> (answerValue .: "noul" >>= probability)
    ChoiceRequest _ options -> do
      unless (kind == "choice") (fail "Incorrect answer kind")
      winner <- answerValue .: "choice"
      unless (winner `elem` map fst options) (fail "Unknown selected option")
      probabilities <- answerValue .: "probabilities" >>= distribution (map fst options)
      confidence <- answerValue .: "confidence" >>= probability
      pure (ChoiceResult (ChoiceAnswer winner probabilities confidence))
    ScaleRequest _ descriptions -> do
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
      pure (ScaleResult (ScaleAnswer value (zip [0..] (map snd probabilities)) confidence))

distribution :: [String] -> Value -> Parser [(String,Double)]
distribution labels = withObject "distribution" $ \values -> do
  unless (sort (map Key.toString (Keys.keys values)) == sort labels) (fail "Incorrect distribution labels")
  probabilities <- mapM (\label -> do
    value <- values .: Key.fromString label >>= probability
    pure (label,value)) labels
  unless (abs (sum (map snd probabilities) - 1) <= 1e-3) (fail "Distribution does not sum to one")
  pure probabilities

probability :: Double -> Parser Double
probability value
  | finite value && value >= 0 && value <= 1 = pure value
  | otherwise = fail "Invalid probability"

finite :: Double -> Bool
finite value = not (isNaN value || isInfinite value)
