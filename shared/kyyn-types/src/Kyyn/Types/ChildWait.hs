{-# LANGUAGE OverloadedStrings #-}
module Kyyn.Types.ChildWait (ChildWaitRequest(..), childWaitCodec) where

import Agentic.Codec (Codec(..), primitive)
import qualified Agentic.Schema as S
import Agentic.Value (Value(..))
import Control.Monad (unless)
import Data.Aeson (encode, eitherDecodeStrict')
import qualified Data.ByteString.Lazy as Bytes
import Data.List (sort)
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import Kyyn.Types.Contract (Description)

-- The request is a private routing envelope, not a reply prompt. The contract
-- uses its existing JSON representation, carried as text in the request codec.
data ChildWaitRequest = ChildWaitRequest Text Description deriving (Eq, Show)

childWaitCodec :: Codec ChildWaitRequest
childWaitCodec = primitive (S.SObject
  [S.Field key (S.schemaOf (S.SString Nothing)) True | key <- ["kyynWait","child","outputContract"]])
  (\(ChildWaitRequest child output) -> Object
    [("kyynWait",String "child"),("child",String child),
     ("outputContract",String (Text.decodeUtf8 (Bytes.toStrict (encode output))))]) decode
  where
    decode (Object fields) = do
      unless (sort (map fst fields) == ["child","kyynWait","outputContract"])
        (Left "Unexpected child wait fields")
      unless (lookup "kyynWait" fields == Just (String "child")) (Left "Invalid child wait kind")
      case (lookup "child" fields,lookup "outputContract" fields) of
        (Just (String child),Just (String output)) ->
          ChildWaitRequest child <$> either (Left . Text.pack) Right (eitherDecodeStrict' (Text.encodeUtf8 output))
        _ -> Left "Invalid child wait request"
    decode _ = Left "Expected a child wait request"

