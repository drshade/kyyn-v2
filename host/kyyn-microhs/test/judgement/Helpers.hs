module Helpers where

import Kyyn.Connectors (Tool)
import qualified Kyyn.Connectors as Connectors
import Kyyn.Judgement
import qualified Kyyn.Query as Query
import Kyyn.Plugin (FetchError(..))
import qualified Kyyn.Plugins.P_fixture.Folder as Files

data Priority = Routine | Important | Urgent deriving (Eq, Show, Enum, Bounded)
data Assessment = Assessment YesNoAnswer (ChoiceAnswer Priority) (ScaleAnswer Priority)

run :: String -> Tool (Either FetchError String)
run key = do
  captured <- Files.content Connectors.documents key
  case captured of
    Left failure -> pure (Left failure)
    Right contents -> do
      result <- judge (Context contents)
        (Assessment <$> ask (yesNo "Is this urgent?" (\yes -> if yes then "Needs immediate action" else "Can wait"))
                    <*> ask (choice "Which priority?" describe)
                    <*> ask (scale "How severe?" describe))
      pure $ case result of
        Left failure -> Right (show failure)
        Right (Assessment (YesNoAnswer probability) (ChoiceAnswer winner distribution confidence) (ScaleAnswer value levels _)) ->
          Right (contents ++ "|" ++ show (winner, basisPoints probability, basisPoints confidence,
            milliLevels value, map option distribution, map option levels,
            probabilityText confidence, scoreText value, atLeast (Probability 9000) probability))
  where
    describe :: Priority -> String
    describe Routine = "low"
    describe Important = "mid"
    describe Urgent = "high"
