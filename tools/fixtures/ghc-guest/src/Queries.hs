{-# LANGUAGE OverloadedRecordDot #-}
module Queries (Args, Total, total) where

import Data.Fixed (Fixed, E2)
import Kyyn.Schema
import Kyyn.Query (readCollection)
import KyynQueryBindings
import Main (Item(..))

-- These types deliberately live beside code that imports generated bindings.
type Args = ()
type Total = Fixed E2

total :: Args -> Query Total
total () = do
  facts <- readCollection items
  pure (sum [item.amount | Fact _ item <- facts])
