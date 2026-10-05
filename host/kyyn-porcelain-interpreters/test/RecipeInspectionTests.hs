-- Recording one-shot recipe projection: tree/DOT/Mermaid, typed wrapper, malformed
-- or request-shaped replies and guest failures; no model/evidence/secret broker.

{-# LANGUAGE GADTs, LambdaCase, OverloadedStrings #-}
module RecipeInspectionTests (recipeInspectionTests) where

import Control.Monad (unless, forM_)
import qualified Data.ByteString.Char8 as Bytes
import Data.Text (Text)
import Effectful (runPureEff)
import Effectful.Dispatch.Dynamic (interpret)
import Kyyn.Domain.Contract (RootContract)
import Kyyn.Domain.Diagnostic (Diagnostic(..))
import Kyyn.Domain.Failure (OperationalFailure)
import Kyyn.Domain.FileTree (fileTree)
import Kyyn.Domain.Path (relativeName)
import Kyyn.Domain.Recipe (DescriptionFormat(..))
import Kyyn.Domain.Root (SourceRoot(..), RootDefinition(..))
import Kyyn.Plumbing.Capability.GuestCompilation (GuestCompilation(..), sourceFiles)
import Kyyn.Plumbing.Capability.GuestExecution (GuestExecution(..))
import Kyyn.Plumbing.Capability.ProcessExecution (ProcessExit(..))
import Kyyn.Plumbing.Interpreter.Failure (runFailure)
import Kyyn.Porcelain.Capability.PluginPreparation (PluginPreparation(..))
import Kyyn.Porcelain.Capability.Tool (ToolPreparation(..))
import Kyyn.Porcelain.Capability.RecipeInspection (describeRecipe)
import Kyyn.Porcelain.Interpreter.RecipeInspection (runRecipeInspection)
import Kyyn.Types.KnowledgeBase (FlowEntryRef(..))

recipeInspectionTests :: RootContract -> IO ()
recipeInspectionTests contract = do
  let empty = either error id (fileTree [])
      source = SourceRoot contract empty (RootDefinition "Example.Root" "Example.metadata" "Example.validate" [] [] empty) []
      perform :: DescriptionFormat -> Bytes.ByteString -> ProcessExit -> Either OperationalFailure (Either [Diagnostic] Text)
      perform format output exit = runPureEff . runFailure
        . interpret (\_ -> \case
            ExecuteCompiled _ input -> if Bytes.null input then pure (output,exit) else error "Description received inputs"
            ExecuteGuest {} -> error "Description installed an interactive guest broker")
        . interpret (\_ (CompileGuest sources) -> do
            let wrapper = [bytes | (path,bytes) <- sourceFiles sources, relativeName path == "KyynRecipeCheck.hs"]
                renderer = case format of Tree -> "renderTree"; Dot -> "dot"; Mermaid -> "mermaid"
            unless (case wrapper of
              [bytes] -> Bytes.pack ("Describe." ++ renderer ++ " (Describe.describe selected)") `Bytes.isInfixOf` bytes
                && "Flow (RecipeInput" `Bytes.isInfixOf` bytes
                && not ("interpret" `Bytes.isInfixOf` bytes)
              _ -> False) (error "Wrong recipe description wrapper")
            pure (Right (error "Recording interpreter does not read the compiled artifact")))
        . interpret (\_ -> \case
            PrepareToolBindings _ _ -> pure (Right (empty,[]))
            PrepareTools {} -> error "Description compiled all registered tools")
        . interpret (\_ -> \case
            PreparePlugins _ -> pure (Right [])
            _ -> error "Description invoked plugin validation")
        . runRecipeInspection $ describeRecipe source (FlowEntryRef "Tasks.flow") format
  forM_ [Tree,Dot,Mermaid] $ \format ->
    unless (perform format "\"rendered\"" (ProcessExit 0 "") == Right (Right "rendered"))
      (fail "Description did not decode the selected renderer's text")
  forM_ ["not json", "{\"request\":\"model\"}", "\"one\"\n\"two\""] $ \output ->
    case perform Tree output (ProcessExit 0 "") of
      Right (Left [Diagnostic _ "recipe.description-protocol" _ _]) -> pure ()
      result -> fail ("Malformed description output was accepted: " ++ show result)
  case perform Tree "" (ProcessExit 2 "bad projection") of
    Left _ -> pure ()
    result -> fail ("Guest exit failure was hidden: " ++ show result)
  putStrLn "Recipe descriptions use a typed one-shot projection and reject malformed/protocol output and guest failure."
