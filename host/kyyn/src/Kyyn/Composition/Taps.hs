{-# LANGUAGE DataKinds #-}
module Kyyn.Composition.Taps (dispatchTaps, searchAvailablePlugins, availableGuide) where

import Effectful (Eff, IOE, runEff)
import Data.Aeson (object, (.=))
import Kyyn.Configuration (Host(..), SelectedKb(..))
import Kyyn.Composition.Runtime (finish)
import Kyyn.Domain.Plugin (PluginName)
import Kyyn.Domain.Tap (Tap(..), TapName, tapNameText)
import Kyyn.Plumbing.Capability.DhallHandling (DhallHandling)
import Kyyn.Plumbing.Capability.Git (Git)
import Kyyn.Plumbing.Capability.FileSystem (FileSystem)
import Kyyn.Plumbing.Capability.ProcessExecution (ProcessExecution)
import Kyyn.Plumbing.Capability.Failure (Failure)
import Kyyn.Plumbing.Interpreter.DhallHandling (runDhallHandling)
import Kyyn.Plumbing.Interpreter.Git (runGit)
import Kyyn.Plumbing.Interpreter.FileSystem (runFileSystemIO)
import Kyyn.Plumbing.Interpreter.ProcessExecution (runProcessExecutionIO)
import Kyyn.Plumbing.Interpreter.Failure (runFailure)
import Kyyn.Porcelain.Capability.PluginDiscovery
import Kyyn.Porcelain.Interpreter.PluginDiscovery (runPluginDiscovery)
import qualified Kyyn.Surfaces.Cli as Cli
import Kyyn.Surfaces.Plugins
import Kyyn.Surfaces.Result (Response, refusal, success)

type Discovery = '[PluginDiscovery,DhallHandling,Git,FileSystem,ProcessExecution,Failure,IOE]

execute :: Host -> Eff Discovery Response -> IO Response
execute (Host executable environment temp _ _ _ _) = finish . runEff . runFailure . runProcessExecutionIO
  . runFileSystemIO temp . runGit executable environment . runDhallHandling . runPluginDiscovery

dispatchTaps :: Host -> Cli.TapCommand -> SelectedKb -> IO Response
dispatchTaps host command (SelectedKb kb _ _) = execute host $ case command of
  Cli.ListTaps -> either refusal tapListResult <$> listTaps kb
  Cli.AddTap name source -> either refusal (const (changed "Added" name)) <$> addTap kb (Tap name source)
  Cli.RemoveTap name -> either refusal (const (changed "Removed" name)) <$> removeTap kb name
  Cli.UpdateTaps name -> either refusal tapUpdateResult <$> updateTaps kb name
  where changed action name = success (object ["name" .= tapNameText name]) [action ++ " tap " ++ tapNameText name]

searchAvailablePlugins :: Host -> String -> SelectedKb -> IO Response
searchAvailablePlugins host query (SelectedKb kb _ _) = execute host $
  either refusal pluginSearchResult <$> searchPlugins kb query

availableGuide :: Host -> TapName -> PluginName -> SelectedKb -> IO Response
availableGuide host tap name (SelectedKb kb _ _) = execute host $
  either refusal (pluginGuideResult Nothing Nothing) <$> readAvailableGuide kb tap name
