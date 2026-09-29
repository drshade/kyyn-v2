module Kyyn.Plumbing.Protocol.Tap
  ( decodeTaps, encodeTaps, decodeCatalogue, encodeSync, decodeSync ) where

import Control.Monad (unless)
import Data.Aeson (Value, object, toJSON, (.=), (.:))
import Data.Aeson.Types (Parser, parseEither, withArray, withObject)
import Data.ByteString (ByteString)
import Data.Foldable (toList)
import Data.List (nub)
import qualified Data.Text.Encoding as Text
import Effectful (Eff, (:>))
import Kyyn.Domain.DataType (Shape(..), ScalarKind(..))
import Kyyn.Domain.Diagnostic (Diagnostic, errorDiagnostic)
import Kyyn.Domain.Git (GitRevision, gitUrl, gitUrlText, gitRevision, revisionName)
import Kyyn.Domain.Path (relativePath)
import Kyyn.Domain.Plugin (pluginName)
import Kyyn.Domain.Tap
import Kyyn.Plumbing.Capability.DhallHandling (DhallHandling, decodeValue, encodeValue)

decodeTaps :: DhallHandling :> es => ByteString -> Eff es (Either [Diagnostic] [Tap])
decodeTaps = decode "tap.declarations-invalid" (List tapShape) $ withArray "taps" $ \values -> do
  taps <- traverse parseTap (toList values)
  unique [name | Tap name _ <- taps]
  pure taps

encodeTaps :: DhallHandling :> es => [Tap] -> Eff es (Either [Diagnostic] ByteString)
encodeTaps = encode (List tapShape) . toJSON . map tapValue

decodeCatalogue :: DhallHandling :> es => ByteString -> Eff es (Either [Diagnostic] [CatalogueEntry])
decodeCatalogue = decode "tap.catalogue-invalid" (List catalogueShape) $ withArray "catalogue" $ \values -> do
  entries <- traverse (withObject "entry" $ \o -> CatalogueEntry
    <$> (o .: "name" >>= either fail pure . pluginName) <*> o .: "description"
    <*> (o .: "source" >>= either fail pure . gitUrl)
    <*> (o .: "path" >>= either fail pure . relativePath)) (toList values)
  unique [name | CatalogueEntry name _ _ _ <- entries]
  pure entries

encodeSync :: DhallHandling :> es => (Tap, GitRevision) -> Eff es (Either [Diagnostic] ByteString)
encodeSync (tap,revision) = encode syncShape (object ["tap" .= tapValue tap,"revision" .= revisionName revision])

decodeSync :: DhallHandling :> es => ByteString -> Eff es (Either [Diagnostic] (Tap,GitRevision))
decodeSync = decode "tap.cache-invalid" syncShape $ withObject "tap sync" $ \o ->
  (,) <$> (o .: "tap" >>= parseTap) <*> (o .: "revision" >>= either fail pure . gitRevision)

tapShape, catalogueShape, syncShape, text :: Shape
text = Scalar TextScalar
tapShape = Record [("name",text),("source",text)]
catalogueShape = Record [("name",text),("description",text),("source",text),("path",text)]
syncShape = Record [("tap",tapShape),("revision",text)]

tapValue :: Tap -> Value
tapValue (Tap name source) = object ["name" .= tapNameText name,"source" .= gitUrlText source]

parseTap :: Value -> Parser Tap
parseTap = withObject "tap" $ \o -> Tap <$> (o .: "name" >>= either fail pure . tapName)
  <*> (o .: "source" >>= either fail pure . gitUrl)

unique :: Eq a => [a] -> Parser ()
unique values = unless (length (nub values) == length values) (fail "Duplicate names")

encode :: DhallHandling :> es => Shape -> Value -> Eff es (Either [Diagnostic] ByteString)
encode shape value = fmap (fmap Text.encodeUtf8) (encodeValue shape value)

decode :: DhallHandling :> es => String -> Shape -> (Value -> Parser a) -> ByteString -> Eff es (Either [Diagnostic] a)
decode code shape parser bytes = case Text.decodeUtf8' bytes of
  Left problem -> pure (Left [errorDiagnostic code (show problem)])
  Right source -> do
    decoded <- decodeValue shape source
    pure (decoded >>= either (Left . pure . errorDiagnostic code) Right . parseEither parser)
