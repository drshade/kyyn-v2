{-# LANGUAGE GADTs #-}
module Kyyn.Plumbing.Protocol.Judgement (decodeRequest, encodeReply) where

import Control.Monad (unless)
import Data.Aeson (Value, Object, ToJSON, object, (.=), (.:), withObject)
import Data.Aeson.Types (Parser)
import Data.Aeson.Key (Key)
import qualified Data.Aeson.KeyMap as Keys
import Data.List (sort)
import Kyyn.Types.Judgement

decodeRequest :: Value -> Parser JudgementRequest
decodeRequest = withObject "judgement request" $ \fields -> do
  exact ["context","questions"] fields
  context <- Context <$> fields .: "context"
  questions <- fields .: "questions" >>= mapM decodeQuestion
  pure (JudgementRequest context questions)

decodeQuestion :: Value -> Parser QuestionSpec
decodeQuestion = withObject "question" $ \fields -> do
  kind <- fields .: "kind"
  question <- fields .: "question"
  case kind :: String of
    "yesNo" -> do
      exact ["kind","question","yes","no"] fields
      YesNoRequest question <$> fields .: "yes" <*> fields .: "no"
    "choice" -> do
      exact ["kind","question","options"] fields
      options <- fields .: "options" >>= mapM (withObject "option" $ \option -> do
        exact ["label","description"] option
        (,) <$> option .: "label" <*> option .: "description")
      pure (ChoiceRequest question options)
    "scale" -> do
      exact ["kind","question","levels"] fields
      ScaleRequest question <$> fields .: "levels"
    _ -> fail "Unknown judgement kind"

encodeReply :: Either JudgementFailure [JudgementAnswer] -> Value
encodeReply (Left failure) = tagged "Left" (failureValue failure)
encodeReply (Right answers) = tagged "Right" (map answerValue answers)

answerValue :: JudgementAnswer -> Value
answerValue (YesNoResult (YesNoAnswer (Probability value))) = tagged "yesNo" (object ["probabilityYes" .= show value])
answerValue (ChoiceResult (ChoiceAnswer winner probabilities confidence)) = tagged "choice" (object
  ["selected" .= winner, "probabilities" .= distribution id probabilities, "confidence" .= show (basisPoints confidence)])
answerValue (ScaleResult (ScaleAnswer value probabilities confidence)) = tagged "scale" (object
  ["score" .= show (milliLevels value), "probabilities" .= distribution show probabilities, "confidence" .= show (basisPoints confidence)])

distribution :: (a -> String) -> [OptionProbability a] -> [Value]
distribution label = map (\(OptionProbability value p) -> object ["label" .= label value,"probability" .= show (basisPoints p)])

failureValue :: JudgementFailure -> Value
failureValue failure = case failure of
  MissingSecret name -> tagged "MissingSecret" name
  InvalidQuestion message -> tagged "InvalidQuestion" message
  AuthenticationRejected -> nullary "AuthenticationRejected"
  RateLimited -> nullary "RateLimited"
  ProviderUnavailable -> nullary "ProviderUnavailable"
  RequestRejected -> nullary "RequestRejected"
  InvalidProviderResponse -> nullary "InvalidProviderResponse"
  where
    nullary label = object ["tag" .= (label :: String)]

tagged :: ToJSON a => String -> a -> Value
tagged label value = object ["tag" .= label,"value" .= value]

exact :: [Key] -> Object -> Parser ()
exact expected fields = unless (sort (Keys.keys fields) == sort expected) (fail "Unexpected judgement fields")
