{-# LANGUAGE DataKinds, TypeFamilies #-}
module Kyyn.Porcelain.Capability.RootExecution
  ( RootExecution(..), PreparedRoot, prepareRoot, preparedRoot, preparedQueries, validateRoot, queryRoot ) where

import Effectful (Eff, Effect, DispatchOf, Dispatch(..), (:>))
import Effectful.Dispatch.Dynamic (send)
import Kyyn.Domain.Diagnostic (Diagnostic, ValidationReport)
import Kyyn.Domain.Root (Root, CheckedValue)
import Kyyn.Domain.Query (QueryDescriptor, QueryResult)
import Kyyn.Porcelain.RootExecution.Types (PreparedRoot(..), PreparedQuery(..))

data RootExecution :: Effect where
  PrepareRoot :: Root -> RootExecution m (Either [Diagnostic] PreparedRoot)
  ValidateRoot :: PreparedRoot -> RootExecution m (Either [Diagnostic] ValidationReport)
  ExecuteQuery :: PreparedRoot -> QueryDescriptor -> CheckedValue -> RootExecution m (Either [Diagnostic] QueryResult)

type instance DispatchOf RootExecution = Dynamic

prepareRoot :: RootExecution :> es => Root -> Eff es (Either [Diagnostic] PreparedRoot)
prepareRoot = send . PrepareRoot

validateRoot :: RootExecution :> es => PreparedRoot -> Eff es (Either [Diagnostic] ValidationReport)
validateRoot = send . ValidateRoot

preparedRoot :: PreparedRoot -> Root
preparedRoot (PreparedRoot root _ _ _ _) = root

preparedQueries :: PreparedRoot -> [QueryDescriptor]
preparedQueries (PreparedRoot _ _ _ queries _) = [descriptor | PreparedQuery descriptor _ _ <- queries]

queryRoot :: RootExecution :> es => PreparedRoot -> QueryDescriptor -> CheckedValue -> Eff es (Either [Diagnostic] QueryResult)
queryRoot root descriptor = send . ExecuteQuery root descriptor
