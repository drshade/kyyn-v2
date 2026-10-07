module Kyyn.Runtime.Recipe (recipeInputCodec) where

import Kyyn.Recipe (RecipeInput(..))
import Kyyn.Runtime.Json

recipeInputCodec :: Codec root -> Codec input -> Codec state
  -> Codec (RecipeInput root input state)
recipeInputCodec rootCodec inputCodec stateCodec = Codec encode decode
  where
    encode (RecipeInput root input state) = record
      [("root",encodeWith rootCodec root),("input",encodeWith inputCodec input),
       ("state",encodeWith stateCodec state)]
    decode value = do
      values <- fields ["root","input","state"] value
      RecipeInput <$> field "root" rootCodec values <*> field "input" inputCodec values
        <*> field "state" stateCodec values
