{-# LANGUAGE GADTs, LambdaCase #-}
module Kyyn.Porcelain.Interpreter.RootOpening (runRootOpening) where

import Control.Monad.Trans.Except (ExceptT(..), runExceptT, throwE)
import Data.Aeson (Value(..))
import qualified Data.Aeson.KeyMap as Keys
import Data.List (isPrefixOf, partition)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import Effectful (Eff, (:>))
import Effectful.Dispatch.Dynamic (interpret)
import Kyyn.Domain.Diagnostic (Diagnostic(..))
import Kyyn.Domain.DataType (Shape(..), ScalarKind(..))
import Kyyn.Domain.Root (Root(..))
import Kyyn.Domain.FileTree (FileTree, fileTree, files)
import Kyyn.Domain.Path (relativePath, relativeName)
import qualified Kyyn.Plumbing.Capability.DhallHandling as Dhall
import qualified Kyyn.Plumbing.Capability.Git as Git
import qualified Kyyn.Plumbing.Capability.SchemaInspection as Schema
import Kyyn.Porcelain.Capability.RootOpening (RootOpening(..))
import Kyyn.Porcelain.Capability.RootStore (RootStore, loadRootValueForChecking)

runRootOpening
  :: (Dhall.DhallHandling :> es, Schema.SchemaInspection :> es, Git.Git :> es, RootStore :> es)
  => FileTree -> Eff (RootOpening : es) a -> Eff es a
runRootOpening sdk = interpret $ \_ -> \case
  OpenCapturedRoot tree -> openTree sdk tree
  LoadRootAt repository revision prefix -> do
    captured <- Git.readTreeAt repository revision prefix
    either (pure . Left) (openTree sdk) captured

openTree
  :: (Dhall.DhallHandling :> es, Schema.SchemaInspection :> es, RootStore :> es)
  => FileTree -> FileTree -> Eff es (Either [Diagnostic] Root)
openTree sdk tree = runExceptT $ do
  manifestPath <- checked (relativePath "kb.dhall")
  manifestBytes <- maybe (rejected "Missing kb.dhall in root subtree") pure (lookup manifestPath (files tree))
  manifestText <- checked (either (Left . show) Right (Text.decodeUtf8' manifestBytes))
  manifest <- ExceptT (Dhall.decodeValue
    (Record [("schemaType", Scalar TextScalar), ("schemaMetadata", Scalar TextScalar)]) manifestText)
  (typeName, metadataName) <- case manifest of
    Object fields -> case (Keys.lookup "schemaType" fields, Keys.lookup "schemaMetadata" fields) of
      (Just (String t), Just (String m)) -> pure (Text.unpack t, Text.unpack m)
      _ -> rejected "Invalid schema selection in kb.dhall"
    _ -> rejected "Expected a manifest record"
  authored <- traverse (\(path,bytes) -> do
    name <- checked (relativePath (drop 4 (relativeName path)))
    pure (name,bytes)) [(p,b) | (p,b) <- files tree, "src/" `isPrefixOf` relativeName p]
  source <- checked (Schema.schemaSource (authored ++ files sdk) typeName metadataName)
  contract <- ExceptT (Schema.inspectSchema source)
  let (factEntries, codeEntries) = partition (\(p,_) -> "facts/" `isPrefixOf` relativeName p) (files tree)
  facts <- checked (fileTree factEntries)
  code <- checked (fileTree codeEntries)
  let root = Root contract facts code
  _ <- ExceptT (loadRootValueForChecking root)
  pure root
  where
    rejected message = throwE [Diagnostic "root.opening" message]
    checked = either rejected pure
