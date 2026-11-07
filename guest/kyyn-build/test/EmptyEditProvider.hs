{-# LANGUAGE TemplateHaskell, EmptyCase, DerivingStrategies, DeriveGeneric #-}
module EmptyEditProvider (Root(..), RootEdit, applyRootEdit) where

import Kyyn.Build.Edits (rootEdits)
import qualified Kyyn.Edit as Edit

-- The initial KB has a nullary Root and no collections. Its generated edit
-- type is empty; generating it must not demand record selectors.
data Root = Root

$(rootEdits ''Root [])
