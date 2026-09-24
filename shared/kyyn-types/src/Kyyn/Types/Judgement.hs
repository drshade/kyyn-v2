{-# LANGUAGE GADTs #-}
module Kyyn.Types.Judgement
  ( Context(..), YesNoAnswer(..), ChoiceAnswer(..), ScaleAnswer(..), Judged(..)
  , JudgementFailure(..), JudgementRequest(..), SomeJudgementRequest(..)
  , validateQuestion
  ) where

import Data.List (nub)

newtype Context = Context String deriving (Eq, Show)
data YesNoAnswer = YesNoAnswer { probabilityYes :: Double } deriving (Eq, Show)
data ChoiceAnswer a = ChoiceAnswer
  { selected :: a, choiceProbabilities :: [(a, Double)], choiceConfidence :: Double }
  deriving (Eq, Show)
data ScaleAnswer a = ScaleAnswer
  { score :: Double, scaleProbabilities :: [(a, Double)], scaleConfidence :: Double }
  deriving (Eq, Show)
data Judged a = Judged { model :: String, answer :: a } deriving (Eq, Show)

data JudgementFailure
  = MissingSecret String
  | InvalidQuestion String
  | AuthenticationRejected
  | RateLimited
  | ProviderUnavailable
  | RequestRejected
  | InvalidProviderResponse
  deriving (Eq, Show)

data JudgementRequest a where
  YesNoRequest :: Context -> String -> JudgementRequest YesNoAnswer
  ChoiceRequest :: Context -> String -> [(String, String)] -> JudgementRequest (ChoiceAnswer String)
  ScaleRequest :: Context -> String -> [String] -> JudgementRequest (ScaleAnswer Integer)

data SomeJudgementRequest where
  SomeJudgementRequest :: JudgementRequest a -> SomeJudgementRequest

validateQuestion :: JudgementRequest a -> Either JudgementFailure ()
validateQuestion request = case request of
  YesNoRequest _ question -> nonempty question
  ChoiceRequest _ question options -> do
    nonempty question
    let labels = map fst options
    if null labels || length (take 256 labels) > 255 || any null labels || length (nub labels) /= length labels
      then Left (InvalidQuestion "Choice requires 1–255 distinct nonempty labels.") else Right ()
  ScaleRequest _ question levels -> do
    nonempty question
    if length (take 11 levels) < 2 || length (take 11 levels) > 10
      then Left (InvalidQuestion "Scale requires 2–10 ordered levels.") else Right ()
  where
    nonempty value = if null value then Left (InvalidQuestion "Question must not be empty.") else Right ()
