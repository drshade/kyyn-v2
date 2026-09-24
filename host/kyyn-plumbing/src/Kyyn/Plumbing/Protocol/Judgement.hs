{-# LANGUAGE GADTs #-}
module Kyyn.Plumbing.Protocol.Judgement (decodeRequest, encodeReply) where

import Control.Monad (unless)
import Data.Aeson (Value, Object, ToJSON, object, (.=), (.:), withObject)
import Data.Aeson.Types (Parser)
import Data.Aeson.Key (Key)
import qualified Data.Aeson.KeyMap as Keys
import Data.List (sort)
import Kyyn.Types.Judgement

decodeRequest :: Value -> Parser SomeJudgementRequest
decodeRequest = withObject "judgement request" $ \fields -> do
  kind <- fields .: "kind"
  context <- Context <$> fields .: "context"
  question <- fields .: "question"
  case kind :: String of
    "yesNo" -> exact ["kind","context","question"] fields >>
      pure (SomeJudgementRequest (YesNoRequest context question))
    "choice" -> do
      exact ["kind","context","question","options"] fields
      options <- fields .: "options" >>= mapM (withObject "option" $ \option -> do
        exact ["label","description"] option
        (,) <$> option .: "label" <*> option .: "description")
      pure (SomeJudgementRequest (ChoiceRequest context question options))
    "scale" -> do
      exact ["kind","context","question","levels"] fields
      SomeJudgementRequest . ScaleRequest context question <$> fields .: "levels"
    _ -> fail "Unknown judgement kind"

encodeReply :: JudgementRequest a -> Either JudgementFailure (Judged a) -> Value
encodeReply _ (Left failure) = tagged "Left" (failureValue failure)
encodeReply request (Right (Judged identity value)) = tagged "Right" (object
  ["model" .= identity, "answer" .= answerValue request value])

answerValue :: JudgementRequest a -> a -> Value
answerValue (YesNoRequest _ _) (YesNoAnswer value) = object ["probabilityYes" .= show value]
answerValue (ChoiceRequest _ _ _) (ChoiceAnswer winner probabilities confidence) = object
  ["selected" .= winner, "probabilities" .= distribution id probabilities, "confidence" .= show confidence]
answerValue (ScaleRequest _ _ _) (ScaleAnswer value probabilities confidence) = object
  ["score" .= show value, "probabilities" .= distribution show probabilities, "confidence" .= show confidence]

distribution :: (a -> String) -> [(a,Double)] -> [Value]
distribution label = map (\(value,p) -> object ["label" .= label value,"probability" .= show p])

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
