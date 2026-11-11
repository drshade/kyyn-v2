module Kyyn.Plumbing.Protocol.EvolutionSources (captureEvolutionSources) where
import Control.Monad (unless)
import Data.List (isPrefixOf)
import Kyyn.Domain.FileTree (FileTree, files)
import Kyyn.Domain.Path (relativePath, relativeName)
import Kyyn.Plumbing.Capability.GuestCompilation.Types

captureEvolutionSources :: EvolutionSelection -> FileTree -> FileTree -> Either String GuestSources
captureEvolutionSources selection target change = do
  unless (all (\(path,_) -> not (any (\name -> relativeName path == name || (name ++ "/") `isPrefixOf` relativeName path) [".kyyn-change"])) (files target))
    (Left "Target source uses a reserved evolution input directory")
  transformation <- traverse (\(path,bytes) -> (,bytes) <$> relativePath (".kyyn-change/" ++ relativeName path)) (files change)
  guestSources (EvolutionEntries selection) (files target ++ transformation)
