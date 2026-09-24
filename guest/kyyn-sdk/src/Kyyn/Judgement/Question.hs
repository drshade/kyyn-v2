module Kyyn.Judgement.Question
  ( Question, Questions, ask, Context(..), yesNo, choice, scale
  , YesNoAnswer(..), ChoiceAnswer(..), ScaleAnswer(..), JudgementFailure(..)
  , judgementFailureMessage
  ) where

import Kyyn.Judgement.Internal (Question, Questions, ask, yesNo, choice, scale)
import Kyyn.Types.Judgement
