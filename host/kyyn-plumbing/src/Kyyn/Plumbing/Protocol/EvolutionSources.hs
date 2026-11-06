module Kyyn.Plumbing.Protocol.EvolutionSources (captureEvolutionSources) where

import Control.Monad (unless)
import Data.List (isPrefixOf)
import Kyyn.Domain.FileTree (FileTree, files)
import Kyyn.Domain.Path (relativePath, relativeName)
import Kyyn.Plumbing.Capability.GuestCompilation.Types

-- Target owns all build inputs, including its flake and lock. Before is copied
-- as source only, in a private directory; its accepted build environment is not
-- brought into the migration. The guest chooses required dependency closures.
captureEvolutionSources :: EvolutionSelection -> FileTree -> FileTree -> FileTree -> Either String GuestSources
captureEvolutionSources selection before target change = do
  unless (all (\(path,_) -> not (reserved (relativeName path))) (files target))
    (Left "Target source uses a reserved evolution input directory")
  old <- prefix ".kyyn-before/" before
  transformation <- prefix ".kyyn-change/" change
  guestSources (EvolutionEntries selection) (files target ++ old ++ transformation)
  where
    reserved path = any (\name -> path == name || (name ++ "/") `isPrefixOf` path) [".kyyn-before",".kyyn-change"]
    prefix directory tree = traverse (\(path,bytes) -> (,bytes) <$> relativePath (directory ++ relativeName path)) (files tree)
