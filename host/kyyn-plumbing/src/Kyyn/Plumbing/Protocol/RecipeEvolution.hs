module Kyyn.Plumbing.Protocol.RecipeEvolution (identityRecipeEvolutionSource) where
import Data.ByteString (ByteString)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text

identityRecipeEvolutionSource :: String -> ByteString
identityRecipeEvolutionSource _ = Text.encodeUtf8 . Text.pack $ unlines
  ["{-# LANGUAGE OverloadedStrings #-}",
   "module Evolution where", "import Kyyn.Workspace.Evolution",
   "import qualified Kyyn.Workspace.Target as Collections",
   "",
   "evolution :: RecipeEvolution Root RecipeState", "evolution = identityEvolution"]

