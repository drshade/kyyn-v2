module Kyyn.Porcelain.Protocol.RecipeBindings (prepareRecipeTypes) where

import Control.Monad.Trans.Except (ExceptT(..), runExceptT, throwE)
import Data.List (nub, stripPrefix)
import Effectful (Eff, (:>))
import Kyyn.Domain.Diagnostic (Diagnostic, errorDiagnostic, compilerContext)
import Kyyn.Domain.Contract (CheckedContract, checkContract)
import Kyyn.Domain.DataType (DataType(UnitType))
import Kyyn.Types.SchemaMetadata (SchemaMetadata(..))
import Kyyn.Domain.FileTree (FileTree, fileTree, files)
import Kyyn.Domain.Path (RelativePath)
import Kyyn.Domain.Plugin (qualifiedTypeName)
import qualified Kyyn.Plumbing.Capability.SchemaInspection as Schema
import Kyyn.Plumbing.Protocol.RecipeTypes (recipeTypeBinding)

-- Before's extra dependencies join the domain schema closure; After's complete
-- captured source tree is already available to the evolution compiler.
prepareRecipeTypes :: Schema.SchemaInspection :> es
  => FileTree -> FileTree -> FileTree -> FileTree
  -> Eff es (Either [Diagnostic] (FileTree, [RelativePath], [(String,CheckedContract)]))
prepareRecipeTypes sdk before after change = runExceptT $ do
  authored <- checked (fileTree (files after ++ files change))
  imports <- ExceptT (Schema.inspectImports authored)
  let requested = nub [(endpoint,selected) | (_,names) <- imports, name <- names,
        endpoint <- ["Before", "After"],
        Just selected <- [stripPrefix (prefix endpoint) name]]
  generated <- traverse (\(endpoint,selected) -> do
    name <- checked (qualifiedTypeName selected)
    sources <- checked (fileTree (files (if endpoint == "Before" then before else after) ++ files sdk))
    Schema.InspectedSchema contract closure <- ExceptT $ fmap
      (either (Left . map (compilerContext ("recipe state " ++ selected))) Right)
      (Schema.inspectType sources name)
    binding <- checked (recipeTypeBinding (prefix endpoint ++ selected) selected contract)
    pure (binding, if endpoint == "Before" then closure else [], (selected,contract))) requested
  bindings <- checked (fileTree (concat [files binding | (binding,_,_) <- generated]))
  unit <- ExceptT (pure (checkContract UnitType (SchemaMetadata [] [] [])))
  pure (bindings, nub (concat [closure | (_,closure,_) <- generated]),
    ("()",unit) : [contract | (_,_,contract) <- generated])
  where
    prefix endpoint = "Kyyn.Workspace." ++ endpoint ++ ".RecipeTypes."
    checked = either (throwE . pure . errorDiagnostic "recipe.binding") pure
