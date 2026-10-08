{-# LANGUAGE OverloadedStrings #-}
module LocalFile.Config (validate) where

import Kyyn.Validation
import LocalFile.Types (FolderConfig(..))

validate :: FolderConfig -> ValidationReport
validate (FolderConfig directory _)
  | null directory || '\0' `elem` directory = ValidationReport
      [errorDiagnostic "local-file.directory" "Folder directory must be nonempty and contain no NUL"]
  | otherwise = ValidationReport []
