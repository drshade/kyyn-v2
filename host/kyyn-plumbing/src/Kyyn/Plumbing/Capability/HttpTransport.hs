{-# LANGUAGE DataKinds, TypeFamilies, DuplicateRecordFields #-}
module Kyyn.Plumbing.Capability.HttpTransport
  ( HttpTransport(..), sendHttp, HttpRequest(..), HttpResponse(..), HttpError(..) ) where

import Effectful (Eff, Effect, DispatchOf, Dispatch(..), (:>))
import Effectful.Dispatch.Dynamic (send)
import Kyyn.Types.PluginHost (HttpRequest(..), HttpResponse(..), HttpError(..))

data HttpTransport :: Effect where
  SendHttp :: HttpRequest -> HttpTransport m (Either HttpError HttpResponse)
type instance DispatchOf HttpTransport = Dynamic

sendHttp :: HttpTransport :> es => HttpRequest -> Eff es (Either HttpError HttpResponse)
sendHttp = send . SendHttp
