{-# LANGUAGE GADTs, LambdaCase #-}
module Kyyn.Plumbing.Interpreter.DhallHandling (runDhallHandling) where

import Effectful (Eff)
import Effectful.Dispatch.Dynamic (interpret)
import Kyyn.Plumbing.Capability.DhallHandling (DhallHandling(..), decodeValueSource)

runDhallHandling :: Eff (DhallHandling : es) a -> Eff es a
runDhallHandling = interpret $ \_ -> \case
  DecodeValue contract contents -> pure (decodeValueSource contract contents)
