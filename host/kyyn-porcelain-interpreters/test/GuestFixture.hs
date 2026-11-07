{-# LANGUAGE GADTs, LambdaCase #-}
module GuestFixture (fixtureProgram, fixtureTool, fixtureConnector, fixtureText, runFixtureExecution, noRecipePreparation) where

import Kyyn.Domain.CompiledEntry (CompiledEntry, CompiledConnector, compiledEntries, compiledConnectors)
import Kyyn.Domain.Guest (checkGuest)
import Kyyn.Domain.Contract (CheckedContract, descriptionOf, metadataOf)
import qualified Kyyn.Types.Guest as G
import qualified Kyyn.Types.Contract as D
import qualified Data.Text as Text
import Data.ByteString (ByteString)
import Effectful (Eff, (:>))
import Effectful.Dispatch.Dynamic (interpret)
import Kyyn.Plumbing.Capability.GuestExecution (GuestExecution(..))
import Kyyn.Domain.CompiledProgram (CompiledProgram(..), BuildIdentity(..))
import Kyyn.Plumbing.Capability.ProcessExecution
import Kyyn.Porcelain.Capability.PluginPreparation (PluginPreparation)
import Kyyn.Porcelain.Capability.Tool (ToolPreparation)

noRecipePreparation :: Eff (ToolPreparation : PluginPreparation : es) a -> Eff es a
noRecipePreparation = noPlugins . noTools
  where
    noTools :: Eff (ToolPreparation : es) a -> Eff es a
    noTools = interpret $ \_ _ -> error "Fixture without closed recipes prepared tools"
    noPlugins :: Eff (PluginPreparation : es) a -> Eff es a
    noPlugins = interpret $ \_ _ -> error "Fixture without closed recipes prepared plugins"

fixtureProgram :: String -> CompiledProgram
fixtureProgram script = CompiledProgram (BuildIdentity "fixture" "fixture" "fixture.drv" "fixture-output") script "fixture-retention"

executeFixture :: ProcessExecution :> es
  => FilePath -> CompiledProgram -> ByteString -> Eff es (ByteString, ProcessExit)
executeFixture shell (CompiledProgram _ script _) input =
  withProcess (ProcessSpec shell ["-c", "read -r input; " ++ script] "/tmp" []) $ do
    writeStdin input
    closeStdin
    output <- collectStdout
    status <- awaitExit
    pure (output,status)

runFixtureExecution :: ProcessExecution :> es => FilePath -> Eff (GuestExecution : es) a -> Eff es a
runFixtureExecution shell = interpret $ \_ -> \case
  ExecuteCompiled program input -> executeFixture shell program input
  ExecuteGuest {} -> error "One-shot fixture requested a conversational guest"

-- Checked descriptions exercise the same handle attachment as production. The
-- execution interpreter above deliberately supplies a recorded process reply.
fixtureText :: D.Description
fixtureText = D.ScalarDescription (D.TypeIdentity "text" "Data.Text.Internal" "Text" []) D.TextScalar "text" []

fixtureTool :: CompiledProgram -> CheckedContract -> CompiledEntry
fixtureTool program contract = case compiledEntries program checked of
  [entry] -> entry
  _ -> error "Expected one tool fixture"
  where
    selected = G.describeContract (descriptionOf contract) (metadataOf contract) []
    checked = either (error . show) id (checkGuest (G.GuestDescription G.protocolIdentity
      [G.ToolEntry "tool" "tool" "Fixture" (G.ToolContracts selected selected)] []))

fixtureConnector :: CompiledProgram -> Text.Text -> Text.Text -> G.ConnectorEntries CheckedContract -> CompiledConnector
fixtureConnector program plugin kind roles = case compiledConnectors program checked of
  [entry] -> entry
  _ -> error "Expected one connector fixture"
  where
    describe contract = G.describeContract (descriptionOf contract) (metadataOf contract) []
    checked = either (error . show) id (checkGuest (G.GuestDescription G.protocolIdentity
      [G.ConnectorEntry (G.ConnectorIdentity plugin kind) (fmap describe roles)] []))
