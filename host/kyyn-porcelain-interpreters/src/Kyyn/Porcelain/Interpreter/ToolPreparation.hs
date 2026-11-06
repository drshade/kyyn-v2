{-# LANGUAGE GADTs, OverloadedRecordDot #-}
module Kyyn.Porcelain.Interpreter.ToolPreparation (runToolPreparation) where

import Control.Monad.Trans.Except (ExceptT(..), runExceptT, throwE)
import qualified Data.Text as Text
import Effectful (Eff, (:>))
import Effectful.Dispatch.Dynamic (interpret)
import Kyyn.Domain.CompiledEntry (compiledEntries, entryDescription)
import Kyyn.Domain.CompiledProgram (CompiledProgram)
import Kyyn.Domain.Guest (CheckedGuest, InspectedSchema(..))
import Kyyn.Domain.Diagnostic (Diagnostic, errorDiagnostic)
import Kyyn.Domain.FileTree (FileTree, files)
import Kyyn.Domain.Plugin (MethodName(..))
import Kyyn.Domain.Tool (ToolDescriptor(..))
import qualified Kyyn.Types.Guest as G
import Kyyn.Plumbing.Capability.GuestCompilation (GuestCompilation, compileGuest)
import Kyyn.Plumbing.Capability.GuestCompilation.Types (guestSources, GuestSelection(..))
import Kyyn.Plumbing.Capability.GuestInspection (GuestInspection, describeGuest)
import Kyyn.Plumbing.Capability.DhallHandling (DhallHandling)
import Kyyn.Porcelain.Protocol.ModelConfiguration (readModelConfiguration)
import Kyyn.Porcelain.Capability.PluginPreparation (PluginPreparation, preparePluginsFromGuest)
import Kyyn.Porcelain.Capability.Tool

runToolPreparation :: (GuestCompilation :> es, GuestInspection :> es, PluginPreparation :> es, DhallHandling :> es)
  => Eff (ToolPreparation : es) a -> Eff es a
runToolPreparation = interpret $ \_ operation -> case operation of
  PrepareTools code -> runExceptT $ do
    source <- either (throwE . pure . errorDiagnostic "tool.sources") pure (guestSources RootEntries (files code))
    program <- ExceptT (compileGuest source)
    description <- ExceptT (describeGuest program)
    prepare code program description
  PrepareToolsFromGuest code program description -> runExceptT (prepare code program description)

prepare :: (PluginPreparation :> es, DhallHandling :> es)
  => FileTree -> CompiledProgram -> CheckedGuest -> ExceptT [Diagnostic] (Eff es) [PreparedTool]
prepare code program description = do
  model <- ExceptT (readModelConfiguration code)
  plugins <- ExceptT (preparePluginsFromGuest code program description)
  pure [PreparedTool (ToolDescriptor (MethodName (Text.unpack name)) (Text.unpack documentation) input.contract result.contract)
      entry plugins model |
    entry <- compiledEntries program description,
    G.ToolEntry _ name documentation (G.ToolContracts input result) <- [entryDescription entry]]
