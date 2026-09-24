{-# LANGUAGE GADTs #-}
module Kyyn.Types.Judgement
  ( Context(..), YesNoAnswer(..), ChoiceAnswer(..), ScaleAnswer(..)
  , JudgementFailure(..), JudgementRequest(..), QuestionSpec(..), JudgementAnswer(..)
  , validateQuestion, validateRequest, judgementFailureMessage
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

data JudgementFailure
  = MissingSecret String
  | InvalidQuestion String
  | AuthenticationRejected
  | RateLimited
  | ProviderUnavailable
  | RequestRejected
  | InvalidProviderResponse
  deriving (Eq, Show)

data JudgementRequest = JudgementRequest Context [QuestionSpec] deriving (Eq, Show)
data QuestionSpec
  = YesNoRequest String String String
  | ChoiceRequest String [(String, String)]
  | ScaleRequest String [String]
  deriving (Eq, Show)
data JudgementAnswer
  = YesNoResult YesNoAnswer
  | ChoiceResult (ChoiceAnswer String)
  | ScaleResult (ScaleAnswer Integer)
  deriving (Eq, Show)

judgementFailureMessage :: JudgementFailure -> String
judgementFailureMessage failure = case failure of
  MissingSecret name -> "Missing secret " ++ name ++ "; use kyyn-v2 --kb PATH secret set " ++ name
  InvalidQuestion message -> message
  AuthenticationRejected -> "The judgement provider rejected the credential."
  RateLimited -> "The judgement provider is rate-limiting requests."
  ProviderUnavailable -> "The judgement provider is unavailable or timed out."
  RequestRejected -> "The judgement provider rejected the request."
  InvalidProviderResponse -> "The judgement provider returned an invalid response."

validateRequest :: JudgementRequest -> Either JudgementFailure ()
validateRequest (JudgementRequest _ []) = Left (InvalidQuestion "At least one question is required.")
validateRequest (JudgementRequest _ questions) = mapM_ validateQuestion questions

validateQuestion :: QuestionSpec -> Either JudgementFailure ()
validateQuestion request = case request of
  YesNoRequest question yes no -> do
    nonempty question
    if null yes || null no then Left (InvalidQuestion "Yes and no descriptions must not be empty.") else Right ()
  ChoiceRequest question options -> do
    nonempty question
    let labels = map fst options
    if null labels || length (take 256 labels) > 255 || any null labels || length (nub labels) /= length labels
      then Left (InvalidQuestion "Choice requires 1–255 distinct nonempty labels.") else Right ()
  ScaleRequest question levels -> do
    nonempty question
    if length (take 11 levels) < 2 || length (take 11 levels) > 10
      then Left (InvalidQuestion "Scale requires 2–10 ordered levels.") else Right ()
  where
    nonempty value = if null value then Left (InvalidQuestion "Question must not be empty.") else Right ()
