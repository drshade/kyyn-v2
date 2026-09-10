{-# LANGUAGE RankNTypes #-}
module Kyyn.Edit.Internal (Collection(..), execStateT) where

import Control.Monad.Trans.State.Strict (execStateT)
import Kyyn.Types.Fact (Fact)
import Kyyn.Optics (Lens')

-- | A named fact collection within a root. Use generated Before/After handles with within.
data Collection root a = Collection String (Lens' root [Fact a])
