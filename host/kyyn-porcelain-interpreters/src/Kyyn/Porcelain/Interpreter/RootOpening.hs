{-# LANGUAGE GADTs, LambdaCase #-}
module Kyyn.Porcelain.Interpreter.RootOpening (runRootOpening) where

import Control.Monad.Trans.Except (ExceptT(..), runExceptT, throwE)
import Data.List (isPrefixOf, partition)
import Effectful (Eff, (:>))
import Effectful.Dispatch.Dynamic (interpret)
import Kyyn.Domain.Diagnostic (Diagnostic, errorDiagnostic)
import Kyyn.Domain.Contract (checkRootLayout)
import Kyyn.Domain.Root (Root(..), RootDefinition(..))
import Kyyn.Domain.FileTree (FileTree, fileTree, files)
import Kyyn.Domain.Path (relativeName)
import qualified Kyyn.Plumbing.Capability.Git as Git
import qualified Kyyn.Plumbing.Capability.SchemaInspection as Schema
import Kyyn.Porcelain.Capability.RootOpening (RootOpening(..))
import Kyyn.Porcelain.Capability.RootStore (RootStore, readRootDefinition, loadRootValueForChecking)

runRootOpening
  :: (Schema.SchemaInspection :> es, Git.Git :> es, RootStore :> es)
  => FileTree -> Eff (RootOpening : es) a -> Eff es a
runRootOpening sdk = interpret $ \_ -> \case
  OpenCapturedRoot tree -> openTree sdk tree
  LoadRootAt repository revision prefix -> do
    captured <- Git.readTreeAt repository revision prefix
    either (pure . Left) (openTree sdk) captured

openTree
  :: (Schema.SchemaInspection :> es, RootStore :> es)
  => FileTree -> FileTree -> Eff es (Either [Diagnostic] Root)
openTree sdk tree = runExceptT $ do
  RootDefinition typeName metadataName _ _ authored <- ExceptT (readRootDefinition tree)
  source <- checked (Schema.schemaSource (files authored ++ files sdk) typeName metadataName)
  inspected <- ExceptT (Schema.inspectSchema source)
  contract <- ExceptT (pure (checkRootLayout inspected))
  let (factEntries, codeEntries) = partition (\(p,_) -> "facts/" `isPrefixOf` relativeName p) (files tree)
  facts <- checked (fileTree factEntries)
  code <- checked (fileTree codeEntries)
  let root = Root contract facts code
  _ <- ExceptT (loadRootValueForChecking root)
  pure root
  where
    rejected message = throwE [errorDiagnostic "root.opening" message]
    checked = either rejected pure
