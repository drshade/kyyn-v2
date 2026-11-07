-- Compiler reification preserves a flow's private state type when creating a
-- named state alias and a typed definition handle. Wrong Root types are refused.
{-# LANGUAGE TemplateHaskell, TypeApplications, OverloadedStrings #-}
module Main (main) where
import Control.Monad (unless)
import Language.Haskell.TH (mkName, recover)
import qualified RecipeTypeProvider as Provider
import qualified Kyyn.Recipe as Recipe
import Kyyn.Evolution (RecipeDefinition)
import qualified Kyyn.Runtime.Bindings as Bindings
import Kyyn.Runtime.Json (encodeWith, printValue)
import Kyyn.Build.RecipeTypes

$(flowStateAlias (mkName "State") ''Provider.Root 'Provider.flow)
$(flowDefinition (mkName "definition") ''Provider.Root 'Provider.flow "RecipeTypeProvider.flow")

main :: IO ()
main = do
  definition `seq` pure ()
  codec <- either (fail . show) pure (Bindings.contractCodec @State)
  encoded <- either fail pure (printValue (encodeWith codec Provider.initial))
  unless (encoded == "{\"count\":\"1\"}") (fail ("Private recipe state codec changed: " ++ encoded))
  unless $(recover [|True|] (flowStateAlias (mkName "Invalid") ''Provider.Other 'Provider.flow >> [|False|]))
    (fail "Flow with wrong Root accepted")
  putStrLn "Private flow state aliases and definition handles preserve compiler identity and reject wrong Roots."
