{-# LANGUAGE GADTs #-}
module Kyyn.Porcelain.Interpreter.RecipeInspection (runRecipeInspection) where

import Control.Monad.Trans.Except (ExceptT(..), runExceptT, throwE)
import Control.Monad (unless)
import qualified Data.Text as Text
import Data.Aeson (eitherDecodeStrict')
import Effectful (Eff, (:>))
import Effectful.Dispatch.Dynamic (interpret)
import Kyyn.Domain.Diagnostic (errorDiagnostic)
import Kyyn.Domain.Root (SourceRoot(..))
import Kyyn.Domain.Contract (rootSchema, rootType)
import Kyyn.Domain.Recipe (RecipeSignature(..))
import Kyyn.Types.KnowledgeBase (FlowEntryRef(..))
import Kyyn.Plumbing.Capability.SchemaInspection (SchemaInspection, inspectRecipeFunction)
import Kyyn.Plumbing.Protocol.Evolution (evolutionBindings, mergeEvolutionSources)
import Kyyn.Plumbing.Capability.Failure (Failure)
import Kyyn.Plumbing.Capability.GuestCompilation (GuestCompilation, compileGuest)
import Kyyn.Plumbing.Capability.GuestExecution (GuestExecution, executeCompiledEntry)
import Kyyn.Plumbing.Protocol.Recipe (recipeDescriptionSources)
import Kyyn.Porcelain.Capability.PluginPreparation (PluginPreparation, preparePlugins)
import Kyyn.Porcelain.Capability.Tool (ToolPreparation, prepareToolBindings)
import Kyyn.Porcelain.Capability.RecipeInspection (RecipeInspection(..))

runRecipeInspection :: (PluginPreparation :> es, ToolPreparation :> es, SchemaInspection :> es, GuestCompilation :> es,
  GuestExecution :> es, Failure :> es) => Eff (RecipeInspection : es) a -> Eff es a
runRecipeInspection = interpret $ \_ (DescribeRecipe (SourceRoot contract code _ _) entry@(FlowEntryRef name) format) -> runExceptT $ do
  plugins <- ExceptT (preparePlugins code)
  (sources,_) <- ExceptT (prepareToolBindings code plugins)
  let checked = either (throwE . pure . errorDiagnostic "recipe.description-source") pure
  bindings <- checked (evolutionBindings contract contract)
  inspectionSources <- checked (mergeEvolutionSources [sources,bindings])
  RecipeSignature domain _ _ <- ExceptT (inspectRecipeFunction inspectionSources (Text.unpack name))
  unless (domain == rootType (rootSchema contract))
    (throwE [errorDiagnostic "recipe.root-type" "Recipe flow takes a different root type"])
  generated <- either (throwE . pure . errorDiagnostic "recipe.description-source") pure
    (recipeDescriptionSources contract entry format sources)
  program <- ExceptT (compileGuest generated)
  output <- ExceptT (Right <$> executeCompiledEntry "Recipe description" program "")
  either (throwE . pure . errorDiagnostic "recipe.description-protocol") pure (eitherDecodeStrict' output)
