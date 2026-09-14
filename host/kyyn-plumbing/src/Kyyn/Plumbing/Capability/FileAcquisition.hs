{-# LANGUAGE DataKinds, TypeFamilies #-}
module Kyyn.Plumbing.Capability.FileAcquisition (FileAcquisition(..), listSourceFiles, readSourceText) where

import Effectful (Eff, Effect, DispatchOf, Dispatch(..), (:>))
import Effectful.Dispatch.Dynamic (send)
import Kyyn.Domain.Path (DirectoryScope, RelativePath)

data FileAcquisition :: Effect where
  ListSourceFiles :: DirectoryScope -> Bool -> FileAcquisition m (Either String [RelativePath])
  ReadSourceText :: DirectoryScope -> RelativePath -> FileAcquisition m (Either String String)

type instance DispatchOf FileAcquisition = Dynamic

listSourceFiles :: FileAcquisition :> es => DirectoryScope -> Bool -> Eff es (Either String [RelativePath])
listSourceFiles scope = send . ListSourceFiles scope

readSourceText :: FileAcquisition :> es => DirectoryScope -> RelativePath -> Eff es (Either String String)
readSourceText scope = send . ReadSourceText scope
