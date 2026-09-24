{-# LANGUAGE GADTs #-}
module Kyyn.Runtime.Judgement (exchangeJudgement) where

import Kyyn.Runtime.Json
import Kyyn.Runtime.Plugin (exchange)
import Kyyn.Types.Judgement
import Text.JSON.Types (JSValue)

exchangeJudgement :: Integer -> JudgementRequest a -> IO (Either JudgementFailure (Judged a))
exchangeJudgement identity request = exchange identity "judgement" "evaluate" (requestValue request) (replyCodec request)

requestValue :: JudgementRequest a -> JSValue
requestValue request = case request of
  YesNoRequest context question -> base "yesNo" context question []
  ChoiceRequest context question options -> base "choice" context question
    [("options", encodeWith (listCodec optionCodec) options)]
  ScaleRequest context question levels -> base "scale" context question
    [("levels", encodeWith (listCodec stringCodec) levels)]
  where
    base kind (Context context) question extra = record
      ([("kind",encodeWith stringCodec kind),("context",encodeWith stringCodec context),
        ("question",encodeWith stringCodec question)] ++ extra)

optionCodec :: Codec (String,String)
optionCodec = Codec
  (\(label,description) -> record [("label",encodeWith stringCodec label),("description",encodeWith stringCodec description)])
  (\value -> do
    values <- fields ["label","description"] value
    (,) <$> field "label" stringCodec values <*> field "description" stringCodec values)

replyCodec :: JudgementRequest a -> Codec (Either JudgementFailure (Judged a))
replyCodec request = Codec encode decode
  where
    encode (Left failure) = tagged "Left" (Just (encodeWith failureCodec failure))
    encode (Right value) = tagged "Right" (Just (encodeWith (judgedCodec (answerCodec request)) value))
    decode value = do
      (tag,payload) <- variant value
      case (tag,payload) of
        ("Left",Just failure) -> Left <$> decodeWith failureCodec failure
        ("Right",Just result) -> Right <$> decodeWith (judgedCodec (answerCodec request)) result
        _ -> Left "Invalid judgement response"

judgedCodec :: Codec a -> Codec (Judged a)
judgedCodec codec = Codec
  (\(Judged identity value) -> record [("model",encodeWith stringCodec identity),("answer",encodeWith codec value)])
  (\value -> do
    values <- fields ["model","answer"] value
    Judged <$> field "model" stringCodec values <*> field "answer" codec values)

answerCodec :: JudgementRequest a -> Codec a
answerCodec (YesNoRequest _ _) = Codec
  (\(YesNoAnswer value) -> record [("probabilityYes",encodeWith doubleCodec value)])
  (\value -> fields ["probabilityYes"] value >>= fmap YesNoAnswer . field "probabilityYes" doubleCodec)
answerCodec (ChoiceRequest _ _ _) = Codec
  (\(ChoiceAnswer winner probabilities confidence) -> record
    [("selected",encodeWith stringCodec winner),("probabilities",encodeWith (distributionCodec stringCodec) probabilities),
     ("confidence",encodeWith doubleCodec confidence)])
  (\value -> do
    values <- fields ["selected","probabilities","confidence"] value
    ChoiceAnswer <$> field "selected" stringCodec values
      <*> field "probabilities" (distributionCodec stringCodec) values <*> field "confidence" doubleCodec values)
answerCodec (ScaleRequest _ _ _) = Codec
  (\(ScaleAnswer scoreValue probabilities confidence) -> record
    [("score",encodeWith doubleCodec scoreValue),("probabilities",encodeWith (distributionCodec integerCodec) probabilities),
     ("confidence",encodeWith doubleCodec confidence)])
  (\value -> do
    values <- fields ["score","probabilities","confidence"] value
    ScaleAnswer <$> field "score" doubleCodec values
      <*> field "probabilities" (distributionCodec integerCodec) values <*> field "confidence" doubleCodec values)

distributionCodec :: Codec a -> Codec [(a,Double)]
distributionCodec labelCodec = listCodec (Codec
  (\(label,probability) -> record [("label",encodeWith labelCodec label),("probability",encodeWith doubleCodec probability)])
  (\value -> do
    values <- fields ["label","probability"] value
    (,) <$> field "label" labelCodec values <*> field "probability" doubleCodec values))

doubleCodec :: Codec Double
doubleCodec = Codec (encodeWith stringCodec . show) (\value -> do
  text <- decodeWith stringCodec value
  case reads text of
    [(number,"")] | not (isNaN number || isInfinite number) -> Right number
    _ -> Left "Expected finite double string")

failureCodec :: Codec JudgementFailure
failureCodec = Codec encode decode
  where
    encode (MissingSecret name) = tagged "MissingSecret" (Just (encodeWith stringCodec name))
    encode (InvalidQuestion message) = tagged "InvalidQuestion" (Just (encodeWith stringCodec message))
    encode AuthenticationRejected = tagged "AuthenticationRejected" Nothing
    encode RateLimited = tagged "RateLimited" Nothing
    encode ProviderUnavailable = tagged "ProviderUnavailable" Nothing
    encode RequestRejected = tagged "RequestRejected" Nothing
    encode InvalidProviderResponse = tagged "InvalidProviderResponse" Nothing
    decode value = do
      (tag,payload) <- variant value
      case (tag,payload) of
        ("MissingSecret",Just name) -> MissingSecret <$> decodeWith stringCodec name
        ("InvalidQuestion",Just message) -> InvalidQuestion <$> decodeWith stringCodec message
        ("AuthenticationRejected",Nothing) -> Right AuthenticationRejected
        ("RateLimited",Nothing) -> Right RateLimited
        ("ProviderUnavailable",Nothing) -> Right ProviderUnavailable
        ("RequestRejected",Nothing) -> Right RequestRejected
        ("InvalidProviderResponse",Nothing) -> Right InvalidProviderResponse
        _ -> Left "Invalid judgement failure"
