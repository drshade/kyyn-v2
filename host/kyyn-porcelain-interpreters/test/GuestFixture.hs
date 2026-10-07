{-# LANGUAGE GADTs, LambdaCase #-}
module GuestFixture (fixtureProgram, runFixtureExecution, noRecipePreparation) where

import Data.ByteString (ByteString)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import Effectful (Eff, (:>))
import Effectful.Dispatch.Dynamic (interpret)
import Kyyn.Plumbing.Capability.GuestExecution (GuestExecution(..))
import Kyyn.Domain.CompiledProgram (CompiledProgram(..), BuildIdentity(..))
import Kyyn.Domain.Path (relativePath)
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
fixtureProgram script = CompiledProgram (BuildIdentity "fixture" "fixture")
  (either error id (relativePath "fixture.comb"), Text.encodeUtf8 (Text.pack script))

executeFixture :: ProcessExecution :> es
  => FilePath -> CompiledProgram -> ByteString -> Eff es (ByteString, ProcessExit)
executeFixture shell (CompiledProgram _ (_,script)) input =
  withProcess (ProcessSpec shell ["-c", "read -r input; " ++ Text.unpack (Text.decodeUtf8 script)] "/tmp" []) $ do
    writeStdin input
    closeStdin
    output <- collectStdout
    status <- awaitExit
    pure (output,status)

runFixtureExecution :: ProcessExecution :> es => FilePath -> Eff (GuestExecution : es) a -> Eff es a
runFixtureExecution shell = interpret $ \_ -> \case
  ExecuteCompiled program input -> executeFixture shell program input
  ExecuteGuest {} -> error "One-shot fixture requested a conversational guest"
