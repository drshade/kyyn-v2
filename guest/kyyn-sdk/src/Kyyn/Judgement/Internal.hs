{-# LANGUAGE ScopedTypeVariables #-}
module Kyyn.Judgement.Internal (Question, Questions, ask, yesNo, choice, scale, judgeWith) where

import Kyyn.Types.Judgement
import Kyyn.Types.Program (Program)

data Question a = Question QuestionSpec (JudgementAnswer -> Either JudgementFailure a)
data Questions a = Questions [QuestionSpec] ([JudgementAnswer] -> Either JudgementFailure a)

instance Functor Questions where
  fmap f (Questions specs decode) = Questions specs (fmap f . decode)

instance Applicative Questions where
  pure value = Questions [] (\answers -> if null answers then Right value else Left InvalidProviderResponse)
  Questions left decodeLeft <*> Questions right decodeRight = Questions (left ++ right) $ \answers ->
    let (before,after) = splitAt (length left) answers
    in decodeLeft before <*> decodeRight after

-- | Add a typed question to an applicative request without sending it.
ask :: Question a -> Questions a
ask (Question spec decode) = Questions [spec] $ \answers -> case answers of
  [answer] -> decode answer
  _ -> Left InvalidProviderResponse

-- | Ask for a probability of yes, describing both possible answers.
yesNo :: String -> (Bool -> String) -> Question YesNoAnswer
yesNo question describe = Question (YesNoRequest question (describe True) (describe False)) $ \answer ->
  case answer of
    YesNoResult value -> Right value
    _ -> Left InvalidProviderResponse

-- | Choose among the constructors of a finite enumeration.
choice :: forall a. (Bounded a, Enum a, Show a)
       => String -> (a -> String) -> Question (ChoiceAnswer a)
choice question describe = Question (ChoiceRequest question descriptions) convert
  where
    values = [minBound .. maxBound] :: [a]
    labels = [(show value, value) | value <- values]
    descriptions = [(show value, describe value) | value <- values]
    find label = maybe (Left InvalidProviderResponse) Right (lookup label labels)
    convert (ChoiceResult (ChoiceAnswer winner probabilities confidence)) =
      ChoiceAnswer <$> find winner <*> mapM (\(OptionProbability label p) -> (\value -> OptionProbability value p) <$> find label) probabilities <*> pure confidence
    convert _ = Left InvalidProviderResponse

-- | Score on the zero-based levels of a finite enumeration, preserving fractional scores.
scale :: forall a. (Bounded a, Enum a, Show a)
      => String -> (a -> String) -> Question (ScaleAnswer a)
scale question describe = Question (ScaleRequest question (map describe values)) convert
  where
    values = [minBound .. maxBound] :: [a]
    levels = zip [0 :: Integer ..] values
    find index = maybe (Left InvalidProviderResponse) Right (lookup index levels)
    convert (ScaleResult (ScaleAnswer value probabilities confidence)) =
      ScaleAnswer value <$> mapM (\(OptionProbability index p) -> (\level -> OptionProbability level p) <$> find index) probabilities <*> pure confidence
    convert _ = Left InvalidProviderResponse

judgeWith :: (JudgementRequest -> Program calls (Either JudgementFailure [JudgementAnswer]))
          -> Context -> Questions a -> Program calls (Either JudgementFailure a)
judgeWith invoke context (Questions specs decode) = do
  let request = JudgementRequest context specs
  case validateRequest request of
    Left failure -> pure (Left failure)
    Right () -> do
      result <- invoke request
      pure (result >>= decode)
