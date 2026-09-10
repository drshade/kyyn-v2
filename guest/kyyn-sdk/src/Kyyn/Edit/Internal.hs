{-# LANGUAGE RankNTypes #-}
module Kyyn.Edit.Internal (Collection(..), execStateT) where

import Control.Monad.Trans.State.Strict (execStateT)
import Kyyn.Types.Fact (Fact)
import Kyyn.Optics (Lens')

data Collection root a = Collection String (Lens' root [Fact a])
