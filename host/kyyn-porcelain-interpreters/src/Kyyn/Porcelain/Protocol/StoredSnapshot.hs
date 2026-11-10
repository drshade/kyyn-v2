{-# LANGUAGE OverloadedStrings #-}
-- | Read accepted storage without inspecting or running its application.
module Kyyn.Porcelain.Protocol.StoredSnapshot (readStoredSnapshot) where

import Control.Monad (unless, forM)
import Control.Monad.Trans.Except (ExceptT(..), runExceptT, throwE)
import Data.Aeson (Value(..))
import qualified Data.Aeson.Key as Key
import qualified Data.Aeson.KeyMap as Keys
import qualified Data.ByteString as Bytes
import Data.Foldable (toList)
import Data.List (nub, sort, stripPrefix, isPrefixOf)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import Effectful (Eff, (:>))
import Kyyn.Domain.DataType (Shape(..), ScalarKind(..))
import Kyyn.Domain.Diagnostic (Diagnostic, errorDiagnostic)
import Kyyn.Domain.FileTree (FileTree, files)
import Kyyn.Domain.Path (relativeName)
import Kyyn.Domain.StoragePath (encodeComponent, decodeComponent)
import Kyyn.Domain.StoredSnapshot
import Kyyn.Types.Fact (Fact(..), FactId(..), parseFactId)
import Kyyn.Plumbing.Capability.DhallHandling (DhallHandling, inferValue)
import Kyyn.Porcelain.Protocol.RecipePersistence (decodeRecipes)

readStoredSnapshot :: DhallHandling :> es
  => FileTree -> Eff es (Either [Diagnostic] StoredSnapshot)
readStoredSnapshot tree = runExceptT $ do
  RecordedValue residualShape residualValue <- inferFile "facts/root.dhall"
  residual <- case (residualShape,residualValue) of
    (Record shapes,Object values) -> forM shapes $ \(name,shape) ->
      case Keys.lookup (Key.fromString name) values of
        Just value -> pure (Text.pack name,RecordedValue shape value)
        Nothing -> bad "Residual field missing from inferred value"
    _ -> bad "facts/root.dhall must be a record"
  let factPaths = [name | (name,_) <- entries, under "facts" name]
      directories = sort (nub [takeWhile (/= '/') suffix |
        name <- factPaths, Just suffix <- [stripPrefix "facts/" name], name /= "facts/root.dhall"])
  loaded <- forM directories $ \directory -> do
    name <- checked (decodeComponent directory)
    unless (not (Text.null name)) (bad "Empty collection name")
    let prefix = "facts/" ++ directory ++ "/"
    RecordedValue shape value <- inferFile (prefix ++ "index.dhall")
    identities <- case (shape,value) of
      (List (Scalar TextScalar),Array values) -> traverse asIdentity (toList values)
      _ -> bad (prefix ++ "index.dhall must be a list of fact IDs")
    unless (length identities == length (nub identities)) (bad (prefix ++ "duplicate membership IDs"))
    let paths = [prefix ++ encodeComponent identity ++ ".dhall" | FactId identity <- identities]
    members <- forM (zip identities paths) $ \(identity@(FactId expected),path) -> do
      recorded@(RecordedValue memberShape memberValue) <- inferFile path
      case (memberShape,memberValue) of
        (Record shapes,Object values)
          | sort (map fst shapes) == ["id","value"]
          , lookup "id" shapes == Just (Scalar TextScalar)
          , Keys.lookup "id" values == Just (String expected) -> pure (Fact identity recorded)
        _ -> bad (path ++ ": fact envelope or path identity mismatch")
    pure (name,members,(prefix ++ "index.dhall") : paths)
  let expectedFacts = "facts/root.dhall" : concat [paths | (_,_,paths) <- loaded]
  unless (sort expectedFacts == sort factPaths) (bad "Unlisted fact files in snapshot")
  definitions <- ExceptT (decodeRecipes (lookup "recipes.dhall" entries))
  let statePaths = ["recipes/" ++ Text.unpack name ++ "/state.dhall" | Fact (FactId name) _ <- definitions]
      actualStates = [name | (name,_) <- entries, under "recipes" name]
  unless (sort statePaths == sort actualStates) (bad "Each recipe must have exactly one recipes/<id>/state.dhall file")
  states <- forM (zip definitions statePaths) $ \(Fact identity definition,path) ->
    Fact identity . RecordedRecipe definition <$> inferFile path
  pure (StoredSnapshot residual [(name,members) | (name,members,_) <- loaded] states)
  where
    entries = [(relativeName path,bytes) | (path,bytes) <- files tree]
    under prefix name = name == prefix || (prefix ++ "/") `isPrefixOf` name
    inferFile name = do
      bytes <- maybe (bad ("Missing file: " ++ name)) pure (lookup name entries)
      source <- checkedUtf8 bytes
      (shape,value) <- ExceptT (inferValue source)
      pure (RecordedValue shape value)
    asIdentity (String name) = either (bad . Text.unpack) pure (parseFactId name)
    asIdentity _ = bad "Expected a textual fact ID"

checkedUtf8 :: Bytes.ByteString -> ExceptT [Diagnostic] (Eff es) Text.Text
checkedUtf8 = checked . either (Left . show) Right . Text.decodeUtf8'

checked :: Either String a -> ExceptT [Diagnostic] (Eff es) a
checked = either bad pure

bad :: String -> ExceptT [Diagnostic] (Eff es) a
bad = throwE . pure . errorDiagnostic "evolution.snapshot"
