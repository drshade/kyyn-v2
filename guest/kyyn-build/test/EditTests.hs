-- Private collection payloads, selector-free parameterised Roots, ordinary
-- Generic/Contract derivation and the generated edit's exact wire shape.
{-# LANGUAGE TemplateHaskell, DeriveGeneric, DeriveAnyClass, DerivingStrategies #-}
{-# LANGUAGE DataKinds, TypeApplications, EmptyCase, OverloadedStrings, OverloadedRecordDot #-}
module Main (main) where

import Control.Monad (unless)
import qualified Agentic.Value as Value
import Kyyn.Build.Edits (rootEdits)
import Kyyn.Contract
import qualified Kyyn.Edit as Edit
import qualified Kyyn.Runtime.Bindings as Bindings
import Control.Monad.Trans.State.Strict (execStateT)
import qualified Kyyn.Optics as Optics
import qualified Kyyn.Evolution.Proposal as Proposal
import qualified EditProvider as Provider

$(rootEdits ''Provider.Root [("facts-é","items")])

main :: IO ()
main = do
  compiled <- right (compileContract (contract @RootEdit))
  let selected = Edit_items Provider.appendOne
      encoded = compiled.codec.encode selected
      expected = Value.Object [("tag",Value.String "Edit_items"),("value",Value.Object
        [("tag",Value.String "Append"),("value",Value.Object
          [("id",Value.String "one"),("value",Value.Object [("amount",Value.String "2")])])])]
  unless (encoded == expected) (fail ("Generated edit wire shape changed: " ++ show encoded))
  decoded <- right (compiled.codec.decode encoded)
  updated <- right (execStateT (applyRootEdit decoded) Provider.initial)
  unless (Provider.count updated == 1) (fail "Generated optic did not update the private payload collection")
  putStrLn "Compiler-generated edits preserve private payloads, aliases, optics and exact wire values."

right :: Show e => Either e a -> IO a
right = either (fail . show) pure
