{-# LANGUAGE GADTs, LambdaCase #-}
module Kyyn.Porcelain.Interpreter.WorkspaceStore (runWorkspaceStore) where

import Control.Monad.Trans.Except (ExceptT(..), runExceptT, throwE)
import Data.Aeson (Value(..), object, (.=))
import qualified Data.Aeson.KeyMap as Keys
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import Effectful (Eff, (:>))
import Effectful.Dispatch.Dynamic (interpret)
import Kyyn.Domain.DataType (Shape(..), ScalarKind(..))
import Kyyn.Domain.Diagnostic (Diagnostic, errorDiagnostic)
import Kyyn.Domain.FileTree (files, fileTree)
import Kyyn.Domain.Git (gitRevision, revisionName)
import Kyyn.Domain.Path (relativePath, relativeName)
import Kyyn.Domain.Workspace
import qualified Kyyn.Plumbing.Capability.DhallHandling as Dhall
import Kyyn.Porcelain.Capability.WorkspaceStore (WorkspaceStore(..))

runWorkspaceStore :: Dhall.DhallHandling :> es => Eff (WorkspaceStore : es) a -> Eff es a
runWorkspaceStore = interpret $ \_ -> \case
  ReadWorkspaceSnapshot tree -> runExceptT $ do
    path <- checked (relativePath "manifest.dhall")
    bytes <- checked (maybe (Left "Missing manifest.dhall") Right (lookup path (files tree)))
    source <- checked (either (Left . show) Right (Text.decodeUtf8' bytes))
    decoded <- ExceptT (fmap (either (Left . (errorDiagnostic "workspace.manifest"
      "Expected exactly before, name, explanation and state in manifest.dhall. If this draft has an intermediates field, remove it; only Before and After contracts are supported." :)) Right)
      (Dhall.decodeValue manifestShape source))
    manifest <- checked (parseManifest decoded)
    checked (projectWorkspace manifest tree)
  EncodeWorkspaceSnapshot (WorkspaceSnapshot manifest@(WorkspaceManifest revision name explanation state) before target change notes) -> runExceptT $ do
    encoded <- ExceptT (Dhall.encodeValue manifestShape (object
      [ "before" .= object ["revision" .= revisionName revision]
      , "name" .= name, "explanation" .= explanation, "state" .= object ["tag" .= show state]
      ]))
    manifestPath <- checked (relativePath "manifest.dhall")
    entries <- checked (traverse (\(pathName,bytes) -> (,bytes) <$> relativePath pathName)
      [(prefix ++ relativeName path,bytes) | (prefix,tree) <-
        [("before/",before),("target/",target),("change/",change),("notes/",notes)], (path,bytes) <- files tree])
    tree <- checked (fileTree ((manifestPath,Text.encodeUtf8 encoded) : entries))
    _ <- checked (projectWorkspace manifest tree)
    pure tree

manifestShape :: Shape
manifestShape = Record
  [ ("before", Record [("revision", Scalar TextScalar)])
  , ("name", Scalar TextScalar)
  , ("explanation", Scalar TextScalar)
  , ("state", Union [("Draft", Nothing), ("Ready", Nothing), ("Accepted", Nothing)])
  ]

parseManifest :: Value -> Either String WorkspaceManifest
parseManifest value = do
  before <- field "before" value
  revision <- field "revision" before >>= string >>= gitRevision
  name <- field "name" value >>= string
  explanation <- field "explanation" value >>= string
  state <- field "state" value >>= field "tag" >>= string >>= \tag -> case tag of
    "Draft" -> Right Draft
    "Ready" -> Right Ready
    "Accepted" -> Right Accepted
    _ -> Left "Unknown evolution state"
  pure (WorkspaceManifest revision name explanation state)
  where
    field key (Object fields) = maybe (Left "Missing workspace manifest field") Right (Keys.lookup key fields)
    field _ _ = Left "Expected workspace manifest record"
    string (String text) = Right (Text.unpack text)
    string _ = Left "Expected workspace manifest text"

checked :: Either String a -> ExceptT [Diagnostic] (Eff es) a
checked = either (throwE . pure . errorDiagnostic "workspace.read") pure
