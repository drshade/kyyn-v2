{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
module Kyyn.Edit.Internal (Collection(..), execStateT) where

import Data.Text (Text)

import Control.Monad.Trans.State.Strict (execStateT)
import Kyyn.Types.Fact (Fact)
import Kyyn.Optics (Lens')

-- | A named fact collection within a root. Use generated Before/After handles with within.
data Collection root a = Collection Text (Lens' root [Fact a])
