module ReviewV1 where

data State = State { reviewed :: [String] } deriving (Eq, Show)
