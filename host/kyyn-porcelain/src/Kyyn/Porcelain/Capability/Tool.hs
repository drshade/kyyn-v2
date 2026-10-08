{-# LANGUAGE DataKinds, GADTs, TypeFamilies #-}
module Kyyn.Porcelain.Capability.Tool
  ( ToolPreparation(..), ToolExecution(..), PreparedTool(..), prepareTools, prepareToolBindings, executeTool ) where

import Data.Aeson (Value)
import Effectful (Eff, Effect, DispatchOf, Dispatch(..), (:>))
import Effectful.Dispatch.Dynamic (send)
import Kyyn.Domain.CompiledProgram (CompiledProgram)
import Kyyn.Domain.Diagnostic (Diagnostic)
import Kyyn.Domain.FileTree (FileTree)
import Kyyn.Domain.Model (ModelConfiguration)
import Kyyn.Domain.Tool (ToolDescriptor(..))
import Kyyn.Domain.Value (CheckedValue)
import Kyyn.Domain.Blob (ResolvedBlob)
import Kyyn.Porcelain.Capability.PluginPreparation (PreparedPlugin)

data PreparedTool = PreparedTool ToolDescriptor CompiledProgram [PreparedPlugin] (Maybe ModelConfiguration) deriving (Eq, Show)

data ToolPreparation :: Effect where
  PrepareTools :: FileTree -> [PreparedPlugin] -> ToolPreparation m (Either [Diagnostic] [PreparedTool])
  PrepareToolBindings :: FileTree -> [PreparedPlugin] -> ToolPreparation m (Either [Diagnostic] (FileTree,[String]))
type instance DispatchOf ToolPreparation = Dynamic

data ToolExecution :: Effect where
  ExecuteTool :: PreparedTool -> Value -> ToolExecution m (Either [Diagnostic] (CheckedValue,[ResolvedBlob]))
type instance DispatchOf ToolExecution = Dynamic

prepareTools :: ToolPreparation :> es => FileTree -> [PreparedPlugin] -> Eff es (Either [Diagnostic] [PreparedTool])
prepareTools code = send . PrepareTools code
prepareToolBindings :: ToolPreparation :> es => FileTree -> [PreparedPlugin] -> Eff es (Either [Diagnostic] (FileTree,[String]))
prepareToolBindings code = send . PrepareToolBindings code
executeTool :: ToolExecution :> es => PreparedTool -> Value -> Eff es (Either [Diagnostic] (CheckedValue,[ResolvedBlob]))
executeTool tool = send . ExecuteTool tool
