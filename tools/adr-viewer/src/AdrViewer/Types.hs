-- | The two data layers the viewer works from.
--
-- Evidence is written only by @extract@: a step index of first-parent history and
-- ADR metadata. Curated lanes are written only by an agent following the README:
-- the decisions one ADR has carried, how they supersede each other and when the
-- code realised them. Enumerations are closed; decoding rejects unknown values.
{-# LANGUAGE DeriveGeneric #-}
module AdrViewer.Types
  ( Step(..), Adr(..), Repo(..)
  , Lane(..), Node(..), Kind(..), Realised(..), How(..), Delivery(..), Ended(..), EndedHow(..)
  , Confidence(..), Editorial(..), deliveries
  , Snapshot(..), Question(..), QuestionKind(..), Verdict(..), Importance(..), questionNodeIds, isContradiction
  ) where

import Data.Aeson
import Data.Char (isLower, isUpper, toLower)
import Data.Text (Text)
import GHC.Generics (Generic)

-- | One first-parent commit: a merged PR, or a direct commit.
data Step = Step
  { stepSeq :: Int, stepSha :: Text, stepDate :: Text, stepPr :: Maybe Int
  , stepTitle :: Text, stepAdrs :: [Text] }
  deriving (Eq, Show, Generic)

data Adr = Adr { adrId :: Text, adrTitle :: Maybe Text, adrBorn :: Int, adrDeleted :: Maybe Int }
  deriving (Eq, Show, Generic)

data Repo = Repo { repoName :: Text, repoUrl :: Maybe Text }
  deriving (Eq, Show, Generic)

-- | One ADR's curated decisions, current through 'laneCursor' (a global step seq).
data Lane = Lane
  { laneAdr :: Text, laneTitle :: Text, laneCursor :: Int, laneNodes :: [Node]
  , laneEditorial :: [Editorial], laneNotes :: Text }
  deriving (Eq, Show, Generic)

data Node = Node
  { nodeId :: Text, nodeSeq :: Int, nodePr :: Maybe Int, nodeSummary :: Text
  , nodeDetail :: Text, nodeKind :: Kind, nodeSupersedes :: [Text]
  , nodeSections :: [Text], nodeAnchors :: [Text], nodeRealised :: Realised
  , nodeDeliveries :: Maybe [Delivery], nodeEnded :: Maybe Ended, nodeConfidence :: Confidence }
  deriving (Eq, Show, Generic)

-- | Steps that delivered part of a node before 'nodeRealised' completed it.
-- Omitted when the decision was delivered in one step.
deliveries :: Node -> [Delivery]
deliveries = maybe [] id . nodeDeliveries

data Kind = New | Refine | Replace deriving (Eq, Show, Generic, Enum, Bounded)

data Realised = Realised { realisedHow :: How, realisedSeq :: Maybe Int, realisedEvidence :: Text }
  deriving (Eq, Show, Generic)

data How = SameStep | LaterStep | CodeFirst | Unrealised | Unknown
  deriving (Eq, Show, Generic, Enum, Bounded)

-- | A step whose code delivered part of a decision, without completing it.
data Delivery = Delivery { deliverySeq :: Int, deliveryEvidence :: Text }
  deriving (Eq, Show, Generic)

data Ended = Ended { endedSeq :: Int, endedHow :: EndedHow, endedBy :: Maybe Text }
  deriving (Eq, Show, Generic)

data EndedHow = Replaced | Removed deriving (Eq, Show, Generic, Enum, Bounded)

data Confidence = High | Medium | Low deriving (Eq, Show, Generic, Enum, Bounded)

data Editorial = Editorial { editorialSeq :: Int, editorialPr :: Maybe Int, editorialNote :: Text }
  deriving (Eq, Show, Generic)

-- | One on-demand specification-gap snapshot of an ADR as of 'snapshotStep':
-- the questions blind agents would need answered before implementing it, merged
-- and rated by a judge. Questions the ADR already answers are dropped.
data Snapshot = Snapshot
  { snapshotAdr :: Text, snapshotStep :: Int, snapshotDate :: Text, snapshotRuns :: Int
  , snapshotSummary :: Text, snapshotQuestions :: [Question] }
  deriving (Eq, Show, Generic)

data Question = Question
  { questionText :: Text, questionAsked :: Int, questionVerdict :: Verdict
  , questionImportance :: Importance, questionReason :: Text, questionNodes :: Maybe [Text]
  , questionKind :: Maybe QuestionKind }
  deriving (Eq, Show, Generic)

-- | A gap the ADRs leave open, or two ADRs that conflict. Omitted means a gap.
data QuestionKind = Gap | Contradiction deriving (Eq, Show, Generic, Enum, Bounded)

isContradiction :: Question -> Bool
isContradiction = (== Just Contradiction) . questionKind

-- | Decisions the question is about; omitted when it maps to none.
questionNodeIds :: Question -> [Text]
questionNodeIds = maybe [] id . questionNodes

data Verdict = Unanswered | PartlyAnswered deriving (Eq, Show, Generic, Enum, Bounded)

-- | What changes with the answer: persisted shapes, failure semantics and
-- ownership (high); visible defaults, limits and validation (medium); local
-- detail an implementer can choose and change later (low).
data Importance = HighImpact | MediumImpact | LowImpact deriving (Eq, Ord, Show, Generic, Enum, Bounded)

-- Records drop their type prefix (@nodeSeq@ is @seq@); enums are snake_case.
fields :: Int -> Options
fields n = defaultOptions
  { fieldLabelModifier = lowerFirst . drop n, omitNothingFields = True, rejectUnknownFields = False }
  where lowerFirst (c:cs) = toLower c : cs
        lowerFirst [] = []

enums :: Options
enums = defaultOptions { constructorTagModifier = snake, allNullaryToStringTag = True }
  where snake = drop 1 . concatMap (\c -> if isUpper c then ['_', toLower c] else [c])

-- | @HighImpact@ is @high@.
impact :: Options
impact = defaultOptions { constructorTagModifier = word, allNullaryToStringTag = True }
  where word (c:cs) = toLower c : takeWhile isLower cs
        word [] = []

instance FromJSON Step where parseJSON = genericParseJSON (fields 4)
instance ToJSON Step where toJSON = genericToJSON (fields 4)
instance FromJSON Adr where parseJSON = genericParseJSON (fields 3)
instance ToJSON Adr where toJSON = genericToJSON (fields 3)
instance FromJSON Repo where parseJSON = genericParseJSON (fields 4)
instance ToJSON Repo where toJSON = genericToJSON (fields 4)
instance FromJSON Lane where parseJSON = genericParseJSON (fields 4)
instance ToJSON Lane where toJSON = genericToJSON (fields 4)
instance FromJSON Node where parseJSON = genericParseJSON (fields 4)
instance ToJSON Node where toJSON = genericToJSON (fields 4)
instance FromJSON Realised where parseJSON = genericParseJSON (fields 8)
instance ToJSON Realised where toJSON = genericToJSON (fields 8)
instance FromJSON Delivery where parseJSON = genericParseJSON (fields 8)
instance ToJSON Delivery where toJSON = genericToJSON (fields 8)
instance FromJSON Ended where parseJSON = genericParseJSON (fields 5)
instance ToJSON Ended where toJSON = genericToJSON (fields 5)
instance FromJSON Editorial where parseJSON = genericParseJSON (fields 9)
instance ToJSON Editorial where toJSON = genericToJSON (fields 9)
instance FromJSON Snapshot where parseJSON = genericParseJSON (fields 8)
instance ToJSON Snapshot where toJSON = genericToJSON (fields 8)
instance FromJSON Question where parseJSON = genericParseJSON (fields 8)
instance ToJSON Question where toJSON = genericToJSON (fields 8)
instance FromJSON QuestionKind where parseJSON = genericParseJSON enums
instance ToJSON QuestionKind where toJSON = genericToJSON enums
instance FromJSON Verdict where parseJSON = genericParseJSON enums
instance ToJSON Verdict where toJSON = genericToJSON enums
instance FromJSON Importance where parseJSON = genericParseJSON impact
instance ToJSON Importance where toJSON = genericToJSON impact
instance FromJSON Kind where parseJSON = genericParseJSON enums
instance ToJSON Kind where toJSON = genericToJSON enums
instance FromJSON How where parseJSON = genericParseJSON enums
instance ToJSON How where toJSON = genericToJSON enums
instance FromJSON EndedHow where parseJSON = genericParseJSON enums
instance ToJSON EndedHow where toJSON = genericToJSON enums
instance FromJSON Confidence where parseJSON = genericParseJSON enums
instance ToJSON Confidence where toJSON = genericToJSON enums
