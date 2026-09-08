module Kyyn.Domain.Root
  ( Root(..), CheckedValue(..), FileTree, fileTree, files ) where

import Data.Aeson (Value)
import Data.ByteString (ByteString)
import Data.List (nub, isPrefixOf)
import Kyyn.Domain.Contract (CheckedContract, ContractId)
import Kyyn.Domain.Path (RelativePath, relativeName)

newtype FileTree = FileTree [(RelativePath, ByteString)] deriving (Eq, Show)
data Root = Root { schema :: CheckedContract, facts :: FileTree, code :: FileTree } deriving (Eq, Show)
data CheckedValue = CheckedValue ContractId Value deriving (Eq, Show)

files :: FileTree -> [(RelativePath, ByteString)]
files (FileTree entries) = entries

fileTree :: [(RelativePath, ByteString)] -> Either String FileTree
fileTree entries
  | length names /= length (nub names) = Left "Duplicate file paths"
  | or [ (a ++ "/") `isPrefixOf` b | a <- names, b <- names ] = Left "File/directory collision"
  | otherwise = Right (FileTree entries)
  where names = map (relativeName . fst) entries
