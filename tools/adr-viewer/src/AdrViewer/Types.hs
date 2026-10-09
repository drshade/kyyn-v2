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
  ) where

import Data.Aeson
import Data.Char (isUpper, toLower)
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

-- Records drop their type prefix (@nodeSeq@ is @seq@); enums are snake_case.
fields :: Int -> Options
fields n = defaultOptions
  { fieldLabelModifier = lowerFirst . drop n, omitNothingFields = True, rejectUnknownFields = False }
  where lowerFirst (c:cs) = toLower c : cs
        lowerFirst [] = []

enums :: Options
enums = defaultOptions { constructorTagModifier = snake, allNullaryToStringTag = True }
  where snake = drop 1 . concatMap (\c -> if isUpper c then ['_', toLower c] else [c])

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
instance FromJSON Kind where parseJSON = genericParseJSON enums
instance ToJSON Kind where toJSON = genericToJSON enums
instance FromJSON How where parseJSON = genericParseJSON enums
instance ToJSON How where toJSON = genericToJSON enums
instance FromJSON EndedHow where parseJSON = genericParseJSON enums
instance ToJSON EndedHow where toJSON = genericToJSON enums
instance FromJSON Confidence where parseJSON = genericParseJSON enums
instance ToJSON Confidence where toJSON = genericToJSON enums
