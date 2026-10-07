module ReviewV2 where

data State = State { reviewed :: [String], window :: Maybe String } deriving (Eq, Show)
