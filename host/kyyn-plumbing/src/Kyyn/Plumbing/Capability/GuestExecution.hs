{-# LANGUAGE DataKinds, TypeFamilies #-}
module Kyyn.Plumbing.Capability.GuestExecution (GuestExecution(..), executeGuest) where

import Effectful (Eff, Effect, DispatchOf, Dispatch(..), (:>))
import Effectful.Dispatch.Dynamic (send)
import Data.ByteString (ByteString)
import Kyyn.Domain.CompiledProgram (CompiledProgram)
import Kyyn.Plumbing.Capability.ProcessExecution (ProcessExit)

data GuestExecution :: Effect where
  ExecuteGuest :: CompiledProgram -> ByteString -> (ByteString -> m (Maybe ByteString))
    -> GuestExecution m (ByteString, ProcessExit)

type instance DispatchOf GuestExecution = Dynamic

executeGuest :: GuestExecution :> es => CompiledProgram -> ByteString
  -> (ByteString -> Eff es (Maybe ByteString)) -> Eff es (ByteString, ProcessExit)
executeGuest program input respond = send (ExecuteGuest program input respond)
