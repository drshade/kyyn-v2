{-# LANGUAGE GADTs #-}
module Kyyn.Types.Judgement
  ( Context(..), Probability(..), Score(..), OptionProbability(..), atLeast, probabilityText, scoreText
  , YesNoAnswer(..), ChoiceAnswer(..), ScaleAnswer(..)
  , JudgementFailure(..), JudgementRequest(..), QuestionSpec(..), JudgementAnswer(..)
  , validateQuestion, validateRequest, judgementFailureMessage
  ) where

import Data.List (nub)

newtype Context = Context String deriving (Eq, Show)
-- | Probability in basis points: 0 is impossible and 10000 is certain.
newtype Probability = Probability { basisPoints :: Integer } deriving (Eq, Ord, Show)
-- | A weighted scale score in thousandths of a level: 1250 means 1.250 levels.
newtype Score = Score { milliLevels :: Integer } deriving (Eq, Ord, Show)
-- | One option or scale level and its probability.
data OptionProbability a = OptionProbability { optionValue :: a, optionProbability :: Probability } deriving (Eq, Show)
-- | Test whether a probability meets a threshold: atLeast (Probability 9500) value.
atLeast :: Probability -> Probability -> Bool
atLeast threshold value = value >= threshold
-- | Display a probability as a percentage with two decimal places.
probabilityText :: Probability -> String
probabilityText (Probability value) = fixedText 2 value ++ "%"
-- | Display a score in levels with three decimal places.
scoreText :: Score -> String
scoreText (Score value) = fixedText 3 value

fixedText :: Int -> Integer -> String
fixedText places value = (if value < 0 then "-" else "") ++ show whole ++ "." ++ replicate (places - length digits) '0' ++ digits
  where
    (whole,fraction) = abs value `divMod` (10 ^ places)
    digits = show fraction

data YesNoAnswer = YesNoAnswer { probabilityYes :: Probability } deriving (Eq, Show)
data ChoiceAnswer a = ChoiceAnswer
  { selected :: a, choiceProbabilities :: [OptionProbability a], choiceConfidence :: Probability }
  deriving (Eq, Show)
data ScaleAnswer a = ScaleAnswer
  { scaleScore :: Score, scaleProbabilities :: [OptionProbability a], scaleConfidence :: Probability }
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
