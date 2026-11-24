{-# LANGUAGE TypeOperators #-}
module Kyyn.Plugin.Live (LiveQueryProgram) where

import Kyyn.Types.Program (Program, (:+:))
import Kyyn.Types.PluginHost (Http, Secrets, Waiting)

type LiveQueryProgram = Program (Http :+: (Secrets :+: Waiting))
