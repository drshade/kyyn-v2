{-# LANGUAGE GADTs #-}
module Kyyn.Porcelain.Interpreter.RecipeStore (runRecipeStore) where

import Control.Monad.Trans.Except (ExceptT(..), runExceptT, throwE)
import Effectful (Eff, (:>))
import Effectful.Dispatch.Dynamic (interpret)
import Kyyn.Domain.Diagnostic (Diagnostic, errorDiagnostic)
import Kyyn.Domain.FileTree (FileTree, fileTree)
import Kyyn.Domain.Git (GitRevision)
import Kyyn.Domain.KnowledgeBase (KnowledgeBase(..), knowledgeBasePath)
import Kyyn.Domain.Path (relativePath)
import Kyyn.Domain.Root (RootDefinition(..))
import Kyyn.Plumbing.Capability.Git (Git, readFileAt)
import Kyyn.Porcelain.Capability.RecipeStore
import Kyyn.Porcelain.Capability.RootStore (RootStore, readRootDefinition, readRootCuration)

runRecipeStore :: (Git :> es, RootStore :> es) => Eff (RecipeStore : es) a -> Eff es a
runRecipeStore = interpret $ \_ request -> case request of
  LoadRecipesAt kb revision -> runExceptT $ do
    material <- readDocument kb revision "kb.dhall"
    RootDefinition _ _ _ _ _ recipes _ <- ExceptT (readRootDefinition material)
    pure recipes
  LoadCurationAt kb revision -> runExceptT $ do
    material <- readDocument kb revision "curation.dhall"
    ExceptT (readRootCuration material)

readDocument :: Git :> es => KnowledgeBase -> GitRevision -> String
  -> ExceptT [Diagnostic] (Eff es) FileTree
readDocument kb@(KnowledgeBase repository _) revision name = do
  local <- checked (relativePath name)
  path <- checked (relativePath ("root/" ++ name) >>= knowledgeBasePath kb)
  bytes <- ExceptT (readFileAt repository revision path)
  checked (fileTree (maybe [] (\value -> [(local,value)]) bytes))

checked :: Either String a -> ExceptT [Diagnostic] (Eff es) a
checked = either (throwE . pure . errorDiagnostic "kb.path") pure
