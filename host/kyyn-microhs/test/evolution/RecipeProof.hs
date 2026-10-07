{-# LANGUAGE OverloadedStrings #-}
module RecipeProof (main) where

import Kyyn.Evolution
import Kyyn.Edit.Internal (execStateT)
import Kyyn.Recipe.Internal (KnowledgeBase(..), readRecipeState)
import Kyyn.Runtime.Json (Codec(..), integerCodec, encodeWith, decodeWith)
import Kyyn.Runtime.Evolution (knowledgeBaseCodec)
import Kyyn.Types.Fact (Fact(..), FactId(..))
import qualified Kyyn.Workspace.Before.RecipeTypes.ReviewV1.State as Before
import qualified Kyyn.Workspace.After.RecipeTypes.ReviewV2.State as After
import qualified ReviewV1 as Old
import qualified ReviewV2 as New

main :: IO ()
main = do
  let identity = RecipeId "reviewMail"
      before = openRecipe Before.recipeType "Review relevant emails"
      after = openRecipe After.recipeType "Review relevant emails in this window"
      create = do
        createRecipe identity before (Old.State ["mail-1"])
        createRecipe (RecipeId "other") before (Old.State [])
      migrate = updateRecipe Before.recipeType identity after
        (\(Old.State ids) -> Right (New.State ids (Just "September")))
      codec = knowledgeBaseCodec integerCodec
  input <- either (fail . show) pure (execStateT create (KnowledgeBase 42 []))
  output <- either (fail . show) pure (execStateT migrate input)
  case (input,output) of
    (KnowledgeBase 42 [_,other], KnowledgeBase 42 [Fact (FactId "reviewMail") state,unchanged]) -> do
      unless (unchanged == other) "Migration changed another recipe"
      value <- either (fail . show) pure (readRecipeState identity After.recipeType state)
      unless (value == New.State ["mail-1"] (Just "September")) "Migration lost state"
    _ -> fail "Migration changed recipe membership or domain facts"
  decoded <- either fail pure (decodeWith codec (encodeWith codec output))
  unless (decoded == output) "Recipe runtime codec lost heterogeneous state"
  let Codec _ decode = codec
  _ <- either fail pure (decode (encodeWith codec input))
  putStrLn "Generated recipe-state handles migrate and round-trip heterogeneous state."
  where
    unless True _ = pure ()
    unless False message = fail message
