module Kyyn.Porcelain.Protocol.RecipePersistence (encodeRecipes, decodeRecipes) where

import Data.Aeson.Types (parseEither)
import Data.ByteString (ByteString)
import qualified Data.Text.Encoding as Text
import Effectful (Eff, (:>))
import Kyyn.Domain.Curation (checkRecipes)
import Kyyn.Domain.Diagnostic (Diagnostic, errorDiagnostic)
import Kyyn.Domain.DataType (Shape(..), ScalarKind(..))
import Kyyn.Types.Fact (Fact)
import Kyyn.Types.KnowledgeBase (Recipe)
import Kyyn.Plumbing.Capability.DhallHandling (DhallHandling, encodeValue, decodeValue)
import Kyyn.Plumbing.Protocol.Recipes (recipesShape, legacyRecipeShape, recipesValue, parseRecipes)

encodeRecipes :: DhallHandling :> es => [Fact Recipe] -> Eff es (Either [Diagnostic] ByteString)
encodeRecipes values = case checkRecipes values of
  Left diagnostics -> pure (Left diagnostics)
  Right checked -> fmap (fmap Text.encodeUtf8) (encodeValue recipesShape (recipesValue checked))

decodeRecipes :: DhallHandling :> es => Maybe ByteString -> Eff es (Either [Diagnostic] [Fact Recipe])
decodeRecipes Nothing = pure (Right [])
decodeRecipes (Just bytes) = case Text.decodeUtf8' bytes of
  Left problem -> pure (failure (show problem))
  Right source -> do
    decoded <- decodeValue recipesShape source
    compatible <- case decoded of
      Right value -> pure (Right value)
      Left diagnostics -> do
        old <- decodeValue (List (Record [("id",Scalar TextScalar),("value",legacyRecipeShape)])) source
        pure (either (const (Left diagnostics)) Right old)
    pure $ compatible >>= either failure checkRecipes . parseEither parseRecipes
  where failure = Left . pure . errorDiagnostic "recipe.invalid-data"
