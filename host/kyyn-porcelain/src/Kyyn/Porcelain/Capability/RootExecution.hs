{-# LANGUAGE DataKinds, TypeFamilies #-}
module Kyyn.Porcelain.Capability.RootExecution (RootExecution(..), validateRoot, discoverQueries, queryRoot) where

import Effectful (Eff, Effect, DispatchOf, Dispatch(..), (:>))
import Effectful.Dispatch.Dynamic (send)
import Kyyn.Domain.Diagnostic (Diagnostic, ValidationReport)
import Kyyn.Domain.Root (Root, CheckedValue)
import Kyyn.Domain.Query (QueryDescriptor, QueryResult)

data RootExecution :: Effect where
  ValidateRoot :: Root -> RootExecution m (Either [Diagnostic] ValidationReport)
  DiscoverQueries :: Root -> RootExecution m (Either [Diagnostic] [QueryDescriptor])
  QueryRoot :: Root -> QueryDescriptor -> CheckedValue -> RootExecution m (Either [Diagnostic] QueryResult)

type instance DispatchOf RootExecution = Dynamic

validateRoot :: RootExecution :> es => Root -> Eff es (Either [Diagnostic] ValidationReport)
validateRoot = send . ValidateRoot

discoverQueries :: RootExecution :> es => Root -> Eff es (Either [Diagnostic] [QueryDescriptor])
discoverQueries = send . DiscoverQueries

queryRoot :: RootExecution :> es => Root -> QueryDescriptor -> CheckedValue -> Eff es (Either [Diagnostic] QueryResult)
queryRoot root descriptor = send . QueryRoot root descriptor
