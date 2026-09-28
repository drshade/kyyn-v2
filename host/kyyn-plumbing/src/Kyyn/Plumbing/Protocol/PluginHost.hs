module Kyyn.Plumbing.Protocol.PluginHost
  ( PluginHostCall(..), decodePluginHostCall, httpResult, secretResult, unitResult ) where

import Control.Monad (unless)
import Data.Aeson (Value, Object, ToJSON, object, (.=), (.:), withObject)
import Data.Aeson.Types (Parser)
import Data.Aeson.Key (Key)
import qualified Data.Aeson.KeyMap as Keys
import Data.List (sort)
import Kyyn.Domain.Secret (SecretName, secretName, secretNameText, SecretError(..))
import Kyyn.Types.PluginHost (HttpRequest(..), HttpResponse(..), HttpError)

data PluginHostCall = HttpCall HttpRequest | GetSecret SecretName | PutSecret SecretName String
  | WaitSeconds Int | DisplayInstructions String

decodePluginHostCall :: String -> String -> Value -> Parser PluginHostCall
decodePluginHostCall capability method arguments = case (capability,method) of
  ("http","send") -> exact ["method","url","headers","body"] (\a ->
    HttpCall <$> (HttpRequest <$> a .: "method" <*> a .: "url" <*>
      (a .: "headers" >>= traverse (exact ["name","value"] (\h -> (,) <$> h .: "name" <*> h .: "value"))) <*> a .: "body")) arguments
  ("secrets","get") -> exact ["key"] (\a -> GetSecret <$> key a) arguments
  ("secrets","put") -> exact ["key","value"] (\a -> PutSecret <$> key a <*> a .: "value") arguments
  ("waiting","seconds") -> exact ["seconds"] (\a -> do
    text <- a .: "seconds"
    case reads text of
      [(n,"")] | n >= 0 && n <= toInteger (maxBound :: Int) && show n == text -> pure (WaitSeconds (fromInteger n))
      _ -> fail "Expected nonnegative bounded integer seconds") arguments
  ("login","display") -> exact ["message"] (fmap DisplayInstructions . (.: "message")) arguments
  _ -> fail "Unsupported plugin host capability or method"
  where
    key a = a .: "key" >>= either (const (fail "Invalid secret name")) pure . secretName

httpResult :: Either HttpError HttpResponse -> Value
httpResult (Left problem) = left (object ["tag" .= show problem])
httpResult (Right (HttpResponse status headers body)) = right (object
  ["status" .= show status,"headers" .= [object ["name" .= n,"value" .= v] | (n,v) <- headers],"body" .= body])

secretResult :: Either SecretError String -> Value
secretResult (Left (SecretNotFound key)) = left (object ["tag" .= ("SecretNotFound" :: String),"value" .= secretNameText key])
secretResult (Right value) = right value

unitResult :: Value
unitResult = object []

left :: Value -> Value
left value = object ["tag" .= ("Left" :: String),"value" .= value]
right :: ToJSON a => a -> Value
right value = object ["tag" .= ("Right" :: String),"value" .= value]

exact :: [Key] -> (Object -> Parser a) -> Value -> Parser a
exact expected parse = withObject "plugin host request" $ \o -> do
  unless (sort (Keys.keys o) == sort expected) (fail "Unexpected or missing plugin host fields")
  parse o
