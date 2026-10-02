module Kyyn.Porcelain.Protocol.ModelConfiguration (readModelConfiguration) where

import Data.Bifunctor (first)
import qualified Data.Text.Encoding as Text
import Effectful (Eff, (:>))
import Kyyn.Domain.Diagnostic (Diagnostic, errorDiagnostic)
import Kyyn.Domain.FileTree (FileTree, files)
import Kyyn.Domain.Model (ModelConfiguration)
import Kyyn.Domain.Path (relativeName)
import Kyyn.Plumbing.Capability.DhallHandling (DhallHandling, decodeValue)
import Kyyn.Plumbing.Protocol.ModelConfiguration (configurationShape, decodeConfiguration)

-- | Read the optional model selection from captured root files.
readModelConfiguration :: DhallHandling :> es
  => FileTree -> Eff es (Either [Diagnostic] (Maybe ModelConfiguration))
readModelConfiguration tree = case [bytes | (path,bytes) <- files tree, relativeName path == "model.dhall"] of
  [] -> pure (Right Nothing)
  bytes : _ -> case Text.decodeUtf8' bytes of
    Left _ -> pure (Left [errorDiagnostic "model.configuration" "model.dhall must contain UTF-8 text"])
    Right source -> do
      decoded <- decodeValue configurationShape source
      pure $ decoded >>= fmap Just . first (pure . errorDiagnostic "model.configuration") . decodeConfiguration
