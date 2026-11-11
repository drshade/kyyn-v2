{-# LANGUAGE OverloadedStrings #-}
module Kyyn.Porcelain.Protocol.Views (readViews) where

import Control.Monad (unless)
import Control.Monad.Trans.Except (ExceptT(..), runExceptT, throwE)
import Data.Aeson (withArray, withObject, (.:))
import Data.Aeson.Types (parseEither)
import Data.Foldable (toList)
import Data.List (nub)
import qualified Data.Text.Encoding as Text
import Effectful (Eff, (:>))
import Kyyn.Domain.Diagnostic (Diagnostic, errorDiagnostic)
import Kyyn.Domain.DataType (Shape(..), ScalarKind(..))
import Kyyn.Domain.FileTree (FileTree, files)
import Kyyn.Domain.Path (relativeName)
import Kyyn.Domain.Plugin (bindingName)
import Kyyn.Domain.View
import Kyyn.Plumbing.Capability.DhallHandling (DhallHandling, decodeValue)

-- Independent of schema compilation and other manifest registrations.
readViews :: DhallHandling :> es => FileTree -> Eff es (Either [Diagnostic] [ViewDefinition])
readViews tree = runExceptT $ do
  let entries = [(relativeName p,b) | (p,b) <- files tree]
      bad = throwE . pure . errorDiagnostic "view.declaration"
  bytes <- maybe (bad "Missing kb.dhall") pure (lookup "kb.dhall" entries)
  source <- either (bad . show) pure (Text.decodeUtf8' bytes)
  value <- ExceptT (decodeValue (List (Record [(k,Scalar TextScalar) | k <- ["name","description","path"]]))
    ("(" <> source <> ").views"))
  declarations <- either bad pure (parseEither (withArray "views" (traverse (withObject "view" (\o ->
    (,,) <$> o .: "name" <*> o .: "description" <*> o .: "path")) . toList)) value)
  let names = [n | (n,_,_) <- declarations]
  unless (length names == length (nub names)) (bad "View names must be unique")
  traverse (\(name,description,path) -> do
    _ <- either bad pure (bindingName name)
    selected <- either bad pure (viewPath path)
    unless (path `elem` map fst entries) (bad ("Missing view page: " ++ path))
    pure (ViewDefinition name description selected)) declarations
