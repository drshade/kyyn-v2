{-# LANGUAGE DataKinds, GADTs, TypeFamilies #-}
module Kyyn.Porcelain.Capability.Tool
  ( ToolPreparation(..), ToolExecution(..), PreparedTool(..), prepareTools, prepareToolsFromGuest, executeTool ) where

import Data.Aeson (Value)
import Effectful (Eff, Effect, DispatchOf, Dispatch(..), (:>))
import Effectful.Dispatch.Dynamic (send)
import Kyyn.Domain.CompiledProgram (CompiledProgram)
import Kyyn.Domain.Guest (CheckedGuest)
import Kyyn.Domain.CompiledEntry (CompiledEntry)
import Kyyn.Domain.Diagnostic (Diagnostic)
import Kyyn.Domain.FileTree (FileTree)
import Kyyn.Domain.Model (ModelConfiguration)
import Kyyn.Domain.Tool (ToolDescriptor(..))
import Kyyn.Domain.Value (CheckedValue)
import Kyyn.Domain.Blob (ResolvedBlob)
import Kyyn.Porcelain.Capability.PluginPreparation (PreparedPlugin)

data PreparedTool = PreparedTool ToolDescriptor CompiledEntry [PreparedPlugin] (Maybe ModelConfiguration) deriving (Eq, Show)

data ToolPreparation :: Effect where
  PrepareTools :: FileTree -> ToolPreparation m (Either [Diagnostic] [PreparedTool])
  PrepareToolsFromGuest :: FileTree -> CompiledProgram -> CheckedGuest -> ToolPreparation m (Either [Diagnostic] [PreparedTool])
type instance DispatchOf ToolPreparation = Dynamic

data ToolExecution :: Effect where
  ExecuteTool :: PreparedTool -> Value -> ToolExecution m (Either [Diagnostic] (CheckedValue,[ResolvedBlob]))
type instance DispatchOf ToolExecution = Dynamic

prepareTools :: ToolPreparation :> es => FileTree -> Eff es (Either [Diagnostic] [PreparedTool])
prepareTools = send . PrepareTools
prepareToolsFromGuest :: ToolPreparation :> es => FileTree -> CompiledProgram -> CheckedGuest
  -> Eff es (Either [Diagnostic] [PreparedTool])
prepareToolsFromGuest code program description = send (PrepareToolsFromGuest code program description)
executeTool :: ToolExecution :> es => PreparedTool -> Value -> Eff es (Either [Diagnostic] (CheckedValue,[ResolvedBlob]))
executeTool tool = send . ExecuteTool tool
