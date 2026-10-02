module Kyyn.Runtime.JudgementWire (requestCodec, replyCodec) where

import Agentic.Questions
import Kyyn.Runtime.Json
import Kyyn.Runtime.ModelWire (valueCodec, textCodec, pairCodec)
import qualified Data.Text as T

requestCodec :: Codec JudgeRequest
requestCodec = Codec
  (\(JudgeRequest state questions) -> record
    [("state",encodeWith valueCodec state),("questions",encodeWith (listCodec questionCodec) questions)])
  (\v -> do
    fs <- fields ["state","questions"] v
    JudgeRequest <$> field "state" valueCodec fs <*> field "questions" (listCodec questionCodec) fs)

questionCodec :: Codec QuestionSpec
questionCodec = Codec encode decode
  where
    encode question = case question of
      AskYesNo q -> tagged "YesNo" (Just (encodeWith textCodec q))
      AskChoice q opts -> tagged "Choice" (Just (encodeWith optionsCodec (q,opts)))
      AskScore q opts -> tagged "Score" (Just (encodeWith optionsCodec (q,opts)))
    decode v = do
      (tag,p) <- variant v
      case (tag,p) of
        ("YesNo",Just x) -> AskYesNo <$> decodeWith textCodec x
        ("Choice",Just x) -> uncurry AskChoice <$> decodeWith optionsCodec x
        ("Score",Just x) -> uncurry AskScore <$> decodeWith optionsCodec x
        _ -> Left "Invalid judgement question"
    optionsCodec = pairCodec "question" textCodec "options"
      (listCodec (pairCodec "label" textCodec "description" (optionalCodec textCodec)))

replyCodec :: Codec (Either String [Answer])
replyCodec = Codec encode decode
  where
    encode (Left message) = tagged "Left" (Just (encodeWith stringCodec message))
    encode (Right answers) = tagged "Right" (Just (encodeWith (listCodec answerCodec) answers))
    decode v = do
      (tag,p) <- variant v
      case (tag,p) of
        ("Left",Just x) -> Left <$> decodeWith stringCodec x
        ("Right",Just x) -> Right <$> decodeWith (listCodec answerCodec) x
        _ -> Left "Invalid judgement reply"

answerCodec :: Codec Answer
answerCodec = Codec encode decode
  where
    encode (YesNoAnswer p) = tagged "YesNo" (Just (encodeWith probabilityCodec p))
    encode (ChoiceAnswer chosen ps confidence) = tagged "Choice" (Just (encodeWith choiceCodec (chosen,(ps,confidence))))
    encode (ScoreAnswer position ps confidence) = tagged "Score" (Just (encodeWith scoreCodec (position,(ps,confidence))))
    decode v = do
      (tag,p) <- variant v
      case (tag,p) of
        ("YesNo",Just x) -> YesNoAnswer <$> decodeWith probabilityCodec x
        ("Choice",Just x) -> do
          (chosen,(ps,confidence)) <- decodeWith choiceCodec x
          pure (ChoiceAnswer chosen ps confidence)
        ("Score",Just x) -> do
          (position,(ps,confidence)) <- decodeWith scoreCodec x
          pure (ScoreAnswer position ps confidence)
        _ -> Left "Invalid judgement answer"

choiceCodec :: Codec (T.Text, ([(T.Text,Probability)], Probability))
choiceCodec = pairCodec "chosen" textCodec "distribution" (distributionCodec textCodec)

scoreCodec :: Codec (Double, ([(Int,Probability)], Probability))
scoreCodec = pairCodec "position" finiteCodec "distribution" (distributionCodec indexCodec)

distributionCodec :: Codec a -> Codec ([(a,Probability)],Probability)
distributionCodec label = pairCodec "probabilities"
  (listCodec (pairCodec "label" label "probability" probabilityCodec)) "confidence" probabilityCodec

probabilityCodec :: Codec Probability
probabilityCodec = Codec (encodeWith integerCodec . toInteger . basisPoints) $ \v -> do
  n <- decodeWith integerCodec v
  if n >= 0 && n <= 10000 then Right (fromBasisPoints (fromInteger n / 10000))
    else Left "Invalid probability basis points"

indexCodec :: Codec Int
indexCodec = Codec (encodeWith integerCodec . toInteger) $ \v -> do
  n <- decodeWith integerCodec v
  if n >= 0 && n <= toInteger (maxBound :: Int) then Right (fromInteger n)
    else Left "Invalid level index"

finiteCodec :: Codec Double
finiteCodec = Codec (encodeWith stringCodec . show) $ \v -> do
  s <- decodeWith stringCodec v
  case reads s of
    [(n,"")] | not (isNaN n || isInfinite n) -> Right n
    _ -> Left "Invalid finite score"
