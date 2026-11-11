module LocalFile.Config (validate) where

import qualified Data.Text as Text
import Kyyn.Validation
import LocalFile.Types (FolderConfig(..))

validate :: FolderConfig -> ValidationReport
validate (FolderConfig directory _)
  | Text.null directory || Text.any (== '\0') directory = ValidationReport
      [errorDiagnostic "local-file.directory" "Folder directory must be nonempty and contain no NUL"]
  | otherwise = ValidationReport []
