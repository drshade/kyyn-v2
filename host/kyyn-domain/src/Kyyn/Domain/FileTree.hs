module Kyyn.Domain.FileTree (FileTree, fileTree, files) where

import Data.ByteString (ByteString)
import Data.List (nub, isPrefixOf, sortOn)
import Kyyn.Domain.Path (RelativePath, relativeName)

newtype FileTree = FileTree [(RelativePath, ByteString)] deriving (Eq, Show)

files :: FileTree -> [(RelativePath, ByteString)]
files (FileTree entries) = entries

fileTree :: [(RelativePath, ByteString)] -> Either String FileTree
fileTree entries
  | length names /= length (nub names) = Left "Duplicate file paths"
  | or [ (a ++ "/") `isPrefixOf` b | a <- names, b <- names ] = Left "File/directory collision"
  | otherwise = Right (FileTree (sortOn fst entries))
  where names = map (relativeName . fst) entries
