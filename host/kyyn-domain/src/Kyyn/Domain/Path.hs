module Kyyn.Domain.Path
  ( DirectoryScope, RelativePath, directoryScope, relativePath, scopePath, relativeName, scopedPath ) where

import System.FilePath (isAbsolute, normalise, (</>))

newtype DirectoryScope = DirectoryScope FilePath deriving (Eq, Show)
newtype RelativePath = RelativePath FilePath deriving (Eq, Ord, Show)

directoryScope :: FilePath -> Either String DirectoryScope
directoryScope path
  | isAbsolute path && '\0' `notElem` path = Right (DirectoryScope (normalise path))
  | otherwise = Left "directory scope must be an absolute path"

relativePath :: FilePath -> Either String RelativePath
relativePath path
  | null path || isAbsolute path || any (`elem` path) ['\\', '\0', ':'] = invalid
  | any (`elem` ["", ".", ".."]) (segments path) = invalid
  | otherwise = Right (RelativePath path)
  where
    invalid = Left "file path must contain nonempty relative components, without . or .."
    segments value = case break (== '/') value of
      (part, []) -> [part]
      (part, _:rest) -> part : segments rest

scopePath :: DirectoryScope -> FilePath
scopePath (DirectoryScope path) = path

relativeName :: RelativePath -> FilePath
relativeName (RelativePath path) = path

scopedPath :: DirectoryScope -> RelativePath -> FilePath
scopedPath scope path = scopePath scope </> relativeName path
