{-# LANGUAGE GADTs, RankNTypes, ScopedTypeVariables #-}
module Kyyn.Judgement.Internal (Question, yesNo, choice, scale, judgeWith) where

import Kyyn.Types.Judgement
import Kyyn.Types.Program (Program)

data Question a where
  Question :: (Context -> JudgementRequest b) -> (b -> Either JudgementFailure a) -> Question a

yesNo :: String -> Question YesNoAnswer
yesNo question = Question (\context -> YesNoRequest context question) Right

choice :: forall a. (Bounded a, Enum a, Show a)
       => String -> (a -> String) -> Question (ChoiceAnswer a)
choice question describe = Question (\context -> ChoiceRequest context question descriptions) convert
  where
    values = [minBound .. maxBound] :: [a]
    labels = [(show value, value) | value <- values]
    descriptions = [(show value, describe value) | value <- values]
    find label = maybe (Left InvalidProviderResponse) Right (lookup label labels)
    convert (ChoiceAnswer winner probabilities confidence) =
      ChoiceAnswer <$> find winner <*> mapM (\(label,p) -> (\value -> (value,p)) <$> find label) probabilities <*> pure confidence

scale :: forall a. (Bounded a, Enum a, Show a)
      => String -> (a -> String) -> Question (ScaleAnswer a)
scale question describe = Question (\context -> ScaleRequest context question (map describe values)) convert
  where
    values = [minBound .. maxBound] :: [a]
    levels = zip [0 :: Integer ..] values
    find index = maybe (Left InvalidProviderResponse) Right (lookup index levels)
    convert (ScaleAnswer value probabilities confidence) =
      ScaleAnswer value <$> mapM (\(index,p) -> (\level -> (level,p)) <$> find index) probabilities <*> pure confidence

judgeWith :: (forall a. JudgementRequest a -> Program calls (Either JudgementFailure (Judged a)))
          -> Context -> Question b -> Program calls (Either JudgementFailure (Judged b))
judgeWith invoke context (Question makeRequest convert) = do
  let request = makeRequest context
  case validateQuestion request of
    Left failure -> pure (Left failure)
    Right () -> do
      result <- invoke request
      pure $ do
        Judged identity value <- result
        Judged identity <$> convert value
