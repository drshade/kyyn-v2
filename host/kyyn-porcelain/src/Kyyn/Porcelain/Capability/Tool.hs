{-# LANGUAGE DataKinds, GADTs, TypeFamilies #-}
module Kyyn.Porcelain.Capability.Tool
  ( ToolPreparation(..), ToolExecution(..), PreparedTool(..), prepareTools, executeTool ) where

import Data.Aeson (Value)
import Effectful (Eff, Effect, DispatchOf, Dispatch(..), (:>))
import Effectful.Dispatch.Dynamic (send)
import Kyyn.Domain.CompiledProgram (CompiledProgram)
import Kyyn.Domain.Diagnostic (Diagnostic)
import Kyyn.Domain.FileTree (FileTree)
import Kyyn.Domain.Tool (ToolDescriptor(..))
import Kyyn.Domain.Value (CheckedValue)
import Kyyn.Porcelain.Capability.PluginPreparation (PreparedPlugin)

data PreparedTool = PreparedTool ToolDescriptor CompiledProgram [PreparedPlugin] deriving (Eq, Show)

data ToolPreparation :: Effect where
  PrepareTools :: FileTree -> [PreparedPlugin] -> ToolPreparation m (Either [Diagnostic] [PreparedTool])
type instance DispatchOf ToolPreparation = Dynamic

data ToolExecution :: Effect where
  ExecuteTool :: PreparedTool -> Value -> ToolExecution m (Either [Diagnostic] CheckedValue)
type instance DispatchOf ToolExecution = Dynamic

prepareTools :: ToolPreparation :> es => FileTree -> [PreparedPlugin] -> Eff es (Either [Diagnostic] [PreparedTool])
prepareTools code = send . PrepareTools code
executeTool :: ToolExecution :> es => PreparedTool -> Value -> Eff es (Either [Diagnostic] CheckedValue)
executeTool tool = send . ExecuteTool tool
