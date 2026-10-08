{-# LANGUAGE DataKinds, TypeFamilies #-}
module Kyyn.Porcelain.Capability.RootExecution
  ( RootExecution(..), PreparedRoot, PreparedOutput(..), prepareRoot, preparedRoot, preparedQueries, preparedPlugins, preparedOutputs, validateRoot, queryRoot ) where

import Effectful (Eff, Effect, DispatchOf, Dispatch(..), (:>))
import Effectful.Dispatch.Dynamic (send)
import Kyyn.Domain.Diagnostic (Diagnostic, ValidationReport)
import Kyyn.Domain.Root (Root, CheckedValue)
import Kyyn.Domain.Query (QueryDescriptor, QueryResult)
import Kyyn.Porcelain.RootExecution.Types (PreparedRoot(..), PreparedQuery(..), PreparedOutput(..))
import Kyyn.Porcelain.Capability.PluginPreparation (PreparedPlugin)

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
preparedRoot (PreparedRoot root _ _ _ _ _) = root

preparedQueries :: PreparedRoot -> [QueryDescriptor]
preparedQueries (PreparedRoot _ _ _ queries _ _) = [descriptor | PreparedQuery descriptor _ _ <- queries]

preparedPlugins :: PreparedRoot -> [PreparedPlugin]
preparedPlugins (PreparedRoot _ _ _ _ plugins _) = plugins

preparedOutputs :: PreparedRoot -> [PreparedOutput]
preparedOutputs (PreparedRoot _ _ _ _ _ outputs) = outputs

queryRoot :: RootExecution :> es => PreparedRoot -> QueryDescriptor -> CheckedValue -> Eff es (Either [Diagnostic] QueryResult)
queryRoot root descriptor = send . ExecuteQuery root descriptor
