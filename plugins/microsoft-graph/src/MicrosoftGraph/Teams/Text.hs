module MicrosoftGraph.Teams.Text (plainText, messageSize) where

import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Encoding
import qualified Data.ByteString as Bytes
import Text.HTML.TagSoup (Tag(..), parseTags)

-- A deliberately lossy text view for conversation, not an HTML renderer. The
-- parser decodes entities; separators keep paragraphs and words apart. Ignore
-- script/style bodies rather than offering their content to a model.
plainText :: Text -> Text
plainText = Text.unwords . Text.words . Text.concat . visible . parseTags
  where
    visible [] = []
    visible (TagOpen name _:rest) | Text.toLower name `elem` ["script","style"] =
      visible (drop 1 (dropWhile (\tag -> case tag of TagClose close -> Text.toLower close /= Text.toLower name; _ -> True) rest))
    visible (TagText value:rest) = value : visible rest
    visible (_:rest) = " " : visible rest

-- Size in UTF-8 bytes for the connector's conservative outgoing-message bound.
messageSize :: Text -> Int
messageSize = Bytes.length . Encoding.encodeUtf8
