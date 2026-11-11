{-# LANGUAGE GADTs, OverloadedRecordDot #-}
module Kyyn.Porcelain.Interpreter.RecipeInspection (runRecipeInspection) where

import Control.Monad.Trans.Except (ExceptT(..), runExceptT, throwE)
import Control.Monad (unless)
import Data.Aeson (toJSON)
import Kyyn.Types.Wire (decodeWire)
import Effectful (Eff, (:>))
import Effectful.Dispatch.Dynamic (interpret)
import Kyyn.Domain.Diagnostic (errorDiagnostic)
import Kyyn.Domain.Root (SourceRoot(..))
import Kyyn.Domain.Contract (rootSchema, contractId)
import Kyyn.Domain.FileTree (files)
import Kyyn.Domain.CompiledEntry (compiledEntries, entryDescription)
import Kyyn.Domain.Guest (InspectedSchema(..))
import Kyyn.Types.KnowledgeBase (FlowEntryRef(..))
import qualified Kyyn.Types.Guest as G
import Kyyn.Plumbing.Capability.Failure (Failure)
import Kyyn.Plumbing.Capability.GuestCompilation (GuestCompilation, compileGuest, guestSources, GuestSelection(..), RecipeReference(..))
import Kyyn.Plumbing.Capability.GuestInspection (GuestInspection, describeGuest)
import Kyyn.Plumbing.Capability.GuestExecution (GuestExecution, executeEntry)
import Kyyn.Porcelain.Capability.RecipeInspection (RecipeInspection(..))

runRecipeInspection :: (GuestCompilation :> es, GuestInspection :> es, GuestExecution :> es, Failure :> es)
  => Eff (RecipeInspection : es) a -> Eff es a
runRecipeInspection = interpret $ \_ (DescribeRecipe (SourceRoot contract code _ _) (FlowEntryRef name) format) -> runExceptT $ do
  source <- either (throwE . pure . errorDiagnostic "recipe.sources") pure
    (guestSources (RecipeEntries [ClosedFlow name]) (files code))
  program <- ExceptT (compileGuest source)
  description <- ExceptT (describeGuest program)
  (entry,root) <- case [(selected,domain.contract) | selected <- compiledEntries program description,
      G.RecipeEntry _ actual (G.RecipeContracts domain _ _) <- [entryDescription selected], actual == name] of
    [selected] -> pure selected
    _ -> throwE [errorDiagnostic "recipe.description" "Guest did not describe the selected recipe flow"]
  unless (contractId root == contractId (rootSchema contract))
    (throwE [errorDiagnostic "recipe.root-type" "Recipe flow takes a different Root contract"])
  output <- ExceptT (Right <$> executeEntry entry (toJSON (G.RenderRecipe format)))
  either (throwE . pure . errorDiagnostic "recipe.description-protocol") pure (decodeWire output)
