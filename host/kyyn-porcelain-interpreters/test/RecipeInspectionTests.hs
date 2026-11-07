-- Recorded recipe projection checks typed describe/invoke selection, tree/DOT/
-- Mermaid, malformed replies and guest failures. Real GHC rendering is covered
-- by NativeRecipeTests and the Nix recipe fixture; no model/provider calls here.
{-# LANGUAGE GADTs, LambdaCase, OverloadedStrings #-}
module RecipeInspectionTests (recipeInspectionTests) where

import Control.Monad (unless, forM_)
import Data.Aeson (eitherDecodeStrict', toJSON)
import qualified Data.ByteString.Char8 as Bytes
import Data.Text (Text)
import Effectful (runPureEff)
import Effectful.Dispatch.Dynamic (interpret)
import GuestFixture (fixtureProgram)
import Kyyn.Domain.Contract (RootContract, rootSchema, descriptionOf, metadataOf)
import Kyyn.Domain.Guest (checkGuest)
import Kyyn.Domain.Diagnostic (Diagnostic(..))
import Kyyn.Domain.Failure (OperationalFailure)
import Kyyn.Domain.FileTree (fileTree)
import Kyyn.Domain.Path (relativePath)
import Kyyn.Domain.Recipe (DescriptionFormat(..))
import Kyyn.Domain.Root (SourceRoot(..), RootDefinition(..))
import Kyyn.Plumbing.Capability.GuestCompilation (GuestCompilation(..), selectedBuild, GuestSelection(..), RecipeReference(..))
import Kyyn.Plumbing.Capability.GuestInspection (GuestInspection(..))
import Kyyn.Plumbing.Capability.GuestExecution (GuestExecution(..))
import Kyyn.Plumbing.Capability.ProcessExecution (ProcessExit(..))
import Kyyn.Plumbing.Interpreter.Failure (runFailure)
import Kyyn.Porcelain.Capability.RecipeInspection (describeRecipe)
import Kyyn.Porcelain.Interpreter.RecipeInspection (runRecipeInspection)
import Kyyn.Types.KnowledgeBase (FlowEntryRef(..))
import Kyyn.Types.Contract (Description(UnitDescription))
import Kyyn.Types.SchemaMetadata (SchemaMetadata(..))
import qualified Kyyn.Types.Guest as G

recipeInspectionTests :: RootContract -> IO ()
recipeInspectionTests contract = do
  let tree entries = either error id (fileTree [(either error id (relativePath name),bytes) | (name,bytes) <- entries])
      empty = tree []
      code = tree [("flake.nix","recorded fixture"),("flake.lock","recorded fixture")]
      source = SourceRoot contract code (RootDefinition "Example.Root" "Example.metadata" "Example.validate" [] [] empty []) []
      program = fixtureProgram "not executed"
      root = G.describeContract (descriptionOf (rootSchema contract)) (metadataOf (rootSchema contract)) []
      unit = G.describeContract UnitDescription (SchemaMetadata [] [] []) []
      description = either (error . show) id (checkGuest (G.GuestDescription G.protocolIdentity
        [G.RecipeEntry "recipe" "Tasks.flow" (G.RecipeContracts root unit unit)] []))
      perform :: DescriptionFormat -> Bytes.ByteString -> ProcessExit -> Either OperationalFailure (Either [Diagnostic] Text)
      perform format output exit = runPureEff . runFailure
        . interpret (\_ -> \case
            ExecuteCompiled actual input -> do
              unless (actual == program && eitherDecodeStrict' input == Right (G.Invoke "recipe" (toJSON (G.RenderRecipe format))))
                (error "Description did not invoke the checked artifact and selected renderer")
              pure (output,exit)
            ExecuteGuest {} -> error "Description installed an interactive guest broker")
        . interpret (\_ (DescribeGuest actual) -> do
            unless (actual == program) (error "Description inspected a different artifact")
            pure (Right description))
        . interpret (\_ (CompileGuest sources) -> do
            unless (selectedBuild sources == RecipeEntries [ClosedFlow "Tasks.flow"])
              (error "Description selected another flow")
            pure (Right program))
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
  putStrLn "Recipe descriptions preserve typed selection, retained artifact, renderer, protocol rejection and guest failures."
