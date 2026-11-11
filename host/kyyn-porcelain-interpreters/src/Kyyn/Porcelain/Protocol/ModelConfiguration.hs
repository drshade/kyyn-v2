module Kyyn.Porcelain.Protocol.ModelConfiguration (readModelConfiguration) where

import Data.Bifunctor (first)
import Data.Aeson (Value(..))
import qualified Data.Aeson.KeyMap as Keys
import qualified Data.Text.Encoding as Text
import Effectful (Eff, (:>))
import Kyyn.Domain.Diagnostic (Diagnostic, errorDiagnostic)
import Kyyn.Domain.FileTree (FileTree, files)
import Kyyn.Domain.Model (ModelConfiguration)
import Kyyn.Domain.Path (relativeName)
import Kyyn.Plumbing.Capability.DhallHandling (DhallHandling, inferValue, decodeValue)
import Kyyn.Plumbing.Protocol.ModelConfiguration (configurationShape, decodeConfiguration)

-- | Read the optional model selection from the captured KB manifest.
readModelConfiguration :: DhallHandling :> es
  => FileTree -> Eff es (Either [Diagnostic] (Maybe ModelConfiguration))
readModelConfiguration tree = case [bytes | (path,bytes) <- files tree, relativeName path == "kb.dhall"] of
  [] -> pure (bad "Missing kb.dhall")
  bytes : _ -> case Text.decodeUtf8' bytes of
    Left _ -> pure (bad "kb.dhall must contain UTF-8 text")
    Right source -> do
      inferred <- inferValue source
      case inferred of
        Left diagnostics -> pure (Left diagnostics)
        Right (_,Object fields)
          | not (Keys.member "model" fields) -> pure (Right Nothing)
          | otherwise -> do
              decoded <- decodeValue configurationShape ("(" <> source <> ").model")
              pure $ decoded >>= fmap Just . first (pure . errorDiagnostic "model.configuration") . decodeConfiguration
        Right _ -> pure (bad "kb.dhall must contain a record")
  where bad = Left . pure . errorDiagnostic "model.configuration"
