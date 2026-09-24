module Kyyn.Judgement.Question
  ( Question, Context(..), yesNo, choice, scale
  , YesNoAnswer(..), ChoiceAnswer(..), ScaleAnswer(..), Judged(..), JudgementFailure(..)
  ) where

import Kyyn.Judgement.Internal (Question, yesNo, choice, scale)
import Kyyn.Types.Judgement
