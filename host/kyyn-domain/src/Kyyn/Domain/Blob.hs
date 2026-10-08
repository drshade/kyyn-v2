{-# LANGUAGE OverloadedStrings #-}
module Kyyn.Domain.Blob
  ( BlobRef(..), ResolvedBlob(..), blobReferences, blobValue, parseBlob, sdkBlobRefType, validateBlobRef ) where

import Control.Monad (unless)
import Data.Aeson (Value, object, (.=), (.:))
import Data.Aeson.Types (Parser, parseEither, withObject, withArray)
import qualified Data.Aeson.Key
import Data.Foldable (toList)
import qualified Data.Text as Text
import Kyyn.Domain.DataType
import Kyyn.Types.Blob (BlobRef(..))

data ResolvedBlob = ResolvedBlob BlobRef FilePath deriving (Eq, Show)

sdkBlobRefType :: DataType
sdkBlobRefType = Algebraic "Kyyn.Types.Blob.BlobRef" []
  [Constructor "Kyyn.Types.Blob.BlobRef"
    [(Just "sha256",TextType),(Just "size",IntegerType),(Just "mediaType",TextType),(Just "name",OptionalType TextType)]]

validateBlobRef :: BlobRef -> Either String ()
validateBlobRef (BlobRef hash size _ _) = do
  unless (Text.length hash == 64 && Text.all (`elem` ("0123456789abcdef" :: String)) hash)
    (Left "Invalid blob SHA-256")
  unless (size >= 0) (Left "Invalid blob byte count")

blobValue :: BlobRef -> Value
blobValue (BlobRef hash size media name) = object
  ["sha256" .= hash,"size" .= show size,"mediaType" .= media,"name" .=
    maybe (object ["tag" .= ("None" :: String)])
      (\value -> object ["tag" .= ("Some" :: String),"value" .= value]) name]

parseBlob :: Value -> Parser BlobRef
parseBlob = withObject "blob reference" $ \fields -> do
  hash <- fields .: "sha256"
  encoded <- fields .: "size"
  size <- case reads encoded of
    [(n,"")] | show (n :: Integer) == encoded -> pure n
    _ -> fail "Invalid blob byte count"
  media <- fields .: "mediaType"
  name <- fields .: "name" >>= withObject "blob name" (\v -> do
    tag <- v .: "tag"
    case tag :: String of
      "None" -> pure Nothing
      "Some" -> Just <$> v .: "value"
      _ -> fail "Invalid optional blob name")
  let ref = BlobRef hash size media name
  either fail (const (pure ref)) (validateBlobRef ref)

-- | Follow the checked nominal contract, never a field-name heuristic.
blobReferences :: DataType -> Value -> Either String [BlobRef]
blobReferences datatype = parseEither (walk datatype)
  where
    walk t _ | not (any nominal (reachableTypes t)) = pure []
    walk t value | t == sdkBlobRefType = pure <$> parseBlob value
    walk (Algebraic "Kyyn.Types.Blob.BlobRef" _ _) _ = fail "Unsupported SDK BlobRef representation"
    walk (ListType t) value = concat <$> withArray "list" (mapM (walk t) . toList) value
    walk (OptionalType t) value = withObject "optional" (\o -> do
      tag <- o .: "tag"
      case tag :: String of
        "None" -> pure []
        "Some" -> o .: "value" >>= walk t
        _ -> fail "Invalid optional tag") value
    walk t value | Just payload <- sdkFactPayload t = withObject "fact" (\o -> o .: "value" >>= walk payload) value
    walk (Algebraic _ _ cs@[Constructor _ fields]) value | isRecord cs = fieldsAt fields value
    walk (Algebraic _ _ cs) value = withObject "union" (\o -> do
      tag <- o .: "tag"
      case [fields | Constructor name fields <- cs, short name == tag] of
        [[]] -> pure []
        [fields] | all (\(name,_) -> name /= Nothing) fields -> o .: "value" >>= fieldsAt fields
        [[(Nothing,t)]] -> o .: "value" >>= walk t
        _ -> fail "Invalid union constructor") value
    walk _ _ = pure []
    fieldsAt fields = withObject "record" $ \o -> concat <$> mapM
      (\(name,t) -> o .: fromString name >>= walk t) [(name,t) | (Just name,t) <- fields]
    short = reverse . takeWhile (/= '.') . reverse
    fromString = Data.Aeson.Key.fromString
    nominal (Algebraic "Kyyn.Types.Blob.BlobRef" _ _) = True
    nominal _ = False
