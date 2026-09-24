{-# LANGUAGE DataKinds, TypeFamilies #-}
module Kyyn.Plumbing.Capability.SecretStore
  ( SecretStore(..), readSecret, writeSecret, listSecretNames, removeSecret ) where

import Data.Text (Text)
import Effectful (Eff, Effect, DispatchOf, Dispatch(..), (:>))
import Effectful.Dispatch.Dynamic (send)
import Kyyn.Domain.Secret (SecretName, SecretError)

data SecretStore :: Effect where
  ReadSecret :: SecretName -> SecretStore m (Either SecretError Text)
  WriteSecret :: SecretName -> Text -> SecretStore m ()
  ListSecretNames :: SecretStore m [SecretName]
  RemoveSecret :: SecretName -> SecretStore m Bool
type instance DispatchOf SecretStore = Dynamic

readSecret :: SecretStore :> es => SecretName -> Eff es (Either SecretError Text)
readSecret = send . ReadSecret

writeSecret :: SecretStore :> es => SecretName -> Text -> Eff es ()
writeSecret name = send . WriteSecret name

listSecretNames :: SecretStore :> es => Eff es [SecretName]
listSecretNames = send ListSecretNames

removeSecret :: SecretStore :> es => SecretName -> Eff es Bool
removeSecret = send . RemoveSecret
