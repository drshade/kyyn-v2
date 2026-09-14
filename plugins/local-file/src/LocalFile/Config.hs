module LocalFile.Config (validate) where

import Kyyn.Validation
import LocalFile.Types (FolderConfig(..))

validate :: FolderConfig -> ValidationReport
validate (FolderConfig directory _)
  | null directory || head directory /= '/' = ValidationReport
      [errorDiagnostic "local-file.directory" "Folder directory must be absolute"]
  | otherwise = ValidationReport []
