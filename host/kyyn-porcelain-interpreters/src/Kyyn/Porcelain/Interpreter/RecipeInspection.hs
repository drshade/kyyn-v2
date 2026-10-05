{-# LANGUAGE GADTs #-}
module Kyyn.Porcelain.Interpreter.RecipeInspection (runRecipeInspection) where

import Control.Monad.Trans.Except (ExceptT(..), runExceptT, throwE)
import Data.Aeson (eitherDecodeStrict')
import Effectful (Eff, (:>))
import Effectful.Dispatch.Dynamic (interpret)
import Kyyn.Domain.Diagnostic (errorDiagnostic)
import Kyyn.Domain.Root (SourceRoot(..))
import Kyyn.Plumbing.Capability.Failure (Failure)
import Kyyn.Plumbing.Capability.GuestCompilation (GuestCompilation, compileGuest)
import Kyyn.Plumbing.Capability.GuestExecution (GuestExecution, executeCompiledEntry)
import Kyyn.Plumbing.Protocol.Recipe (recipeDescriptionSources)
import Kyyn.Porcelain.Capability.PluginPreparation (PluginPreparation, preparePlugins)
import Kyyn.Porcelain.Capability.Tool (ToolPreparation, prepareToolBindings)
import Kyyn.Porcelain.Capability.RecipeInspection (RecipeInspection(..))

runRecipeInspection :: (PluginPreparation :> es, ToolPreparation :> es, GuestCompilation :> es,
  GuestExecution :> es, Failure :> es) => Eff (RecipeInspection : es) a -> Eff es a
runRecipeInspection = interpret $ \_ (DescribeRecipe (SourceRoot contract code _ _) entry format) -> runExceptT $ do
  plugins <- ExceptT (preparePlugins code)
  (sources,_) <- ExceptT (prepareToolBindings code plugins)
  generated <- either (throwE . pure . errorDiagnostic "recipe.description-source") pure
    (recipeDescriptionSources contract entry format sources)
  program <- ExceptT (compileGuest generated)
  output <- ExceptT (Right <$> executeCompiledEntry "Recipe description" program "")
  either (throwE . pure . errorDiagnostic "recipe.description-protocol") pure (eitherDecodeStrict' output)
