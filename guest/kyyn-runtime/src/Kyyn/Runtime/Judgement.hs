module Kyyn.Runtime.Judgement (exchangeJudgement) where

import Kyyn.Runtime.Json
import Kyyn.Runtime.Plugin (exchange)
import Kyyn.Types.Judgement
import Text.JSON.Types (JSValue)

exchangeJudgement :: Integer -> JudgementRequest -> IO (Either JudgementFailure [JudgementAnswer])
exchangeJudgement identity request = exchange identity "judgement" "evaluate" (requestValue request) replyCodec

requestValue :: JudgementRequest -> JSValue
requestValue (JudgementRequest (Context context) questions) = record
  [("context",encodeWith stringCodec context),
   ("questions",encodeWith (listCodec questionCodec) questions)]

questionCodec :: Codec QuestionSpec
questionCodec = Codec encode (const (Left "Questions are outbound only"))
  where
    encode request = case request of
      YesNoRequest question yes no -> base "yesNo" question
        [("yes",encodeWith stringCodec yes),("no",encodeWith stringCodec no)]
      ChoiceRequest question options -> base "choice" question
        [("options",encodeWith (listCodec optionCodec) options)]
      ScaleRequest question levels -> base "scale" question
        [("levels",encodeWith (listCodec stringCodec) levels)]
    base kind question extra = record
      ([("kind",encodeWith stringCodec kind),("question",encodeWith stringCodec question)] ++ extra)

optionCodec :: Codec (String,String)
optionCodec = Codec
  (\(label,description) -> record [("label",encodeWith stringCodec label),("description",encodeWith stringCodec description)])
  (\value -> do
    values <- fields ["label","description"] value
    (,) <$> field "label" stringCodec values <*> field "description" stringCodec values)

replyCodec :: Codec (Either JudgementFailure [JudgementAnswer])
replyCodec = Codec encode decode
  where
    encode (Left failure) = tagged "Left" (Just (encodeWith failureCodec failure))
    encode (Right answers) = tagged "Right" (Just (encodeWith (listCodec answerCodec) answers))
    decode value = do
      (tag,payload) <- variant value
      case (tag,payload) of
        ("Left",Just failure) -> Left <$> decodeWith failureCodec failure
        ("Right",Just result) -> Right <$> decodeWith (listCodec answerCodec) result
        _ -> Left "Invalid judgement response"

answerCodec :: Codec JudgementAnswer
answerCodec = Codec encode decode
  where
    encode (YesNoResult value) = tagged "yesNo" (Just (encodeWith yesNoCodec value))
    encode (ChoiceResult value) = tagged "choice" (Just (encodeWith choiceCodec value))
    encode (ScaleResult value) = tagged "scale" (Just (encodeWith scaleCodec value))
    decode value = do
      (tag,payload) <- variant value
      case (tag,payload) of
        ("yesNo",Just answer) -> YesNoResult <$> decodeWith yesNoCodec answer
        ("choice",Just answer) -> ChoiceResult <$> decodeWith choiceCodec answer
        ("scale",Just answer) -> ScaleResult <$> decodeWith scaleCodec answer
        _ -> Left "Invalid judgement answer"

yesNoCodec :: Codec YesNoAnswer
yesNoCodec = Codec
  (\(YesNoAnswer value) -> record [("probabilityYes",encodeWith probabilityCodec value)])
  (\value -> fields ["probabilityYes"] value >>= fmap YesNoAnswer . field "probabilityYes" probabilityCodec)

choiceCodec :: Codec (ChoiceAnswer String)
choiceCodec = Codec
  (\(ChoiceAnswer winner probabilities confidence) -> record
    [("selected",encodeWith stringCodec winner),("probabilities",encodeWith (distributionCodec stringCodec) probabilities),
     ("confidence",encodeWith probabilityCodec confidence)])
  (\value -> do
    values <- fields ["selected","probabilities","confidence"] value
    ChoiceAnswer <$> field "selected" stringCodec values
      <*> field "probabilities" (distributionCodec stringCodec) values <*> field "confidence" probabilityCodec values)

scaleCodec :: Codec (ScaleAnswer Integer)
scaleCodec = Codec
  (\(ScaleAnswer scoreValue probabilities confidence) -> record
    [("score",encodeWith scoreCodec scoreValue),("probabilities",encodeWith (distributionCodec integerCodec) probabilities),
     ("confidence",encodeWith probabilityCodec confidence)])
  (\value -> do
    values <- fields ["score","probabilities","confidence"] value
    ScaleAnswer <$> field "score" scoreCodec values
      <*> field "probabilities" (distributionCodec integerCodec) values <*> field "confidence" probabilityCodec values)

distributionCodec :: Codec a -> Codec [OptionProbability a]
distributionCodec labelCodec = listCodec (Codec
  (\(OptionProbability label p) -> record [("label",encodeWith labelCodec label),("probability",encodeWith probabilityCodec p)])
  (\value -> do
    values <- fields ["label","probability"] value
    OptionProbability <$> field "label" labelCodec values <*> field "probability" probabilityCodec values))

probabilityCodec :: Codec Probability
probabilityCodec = Codec (\(Probability value) -> encodeWith integerCodec value) (\value -> do
  number <- decodeWith integerCodec value
  if number >= 0 && number <= 10000 then Right (Probability number) else Left "Expected probability basis points in 0..10000")

scoreCodec :: Codec Score
scoreCodec = Codec (\(Score value) -> encodeWith integerCodec value) (fmap Score . decodeWith integerCodec)

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
