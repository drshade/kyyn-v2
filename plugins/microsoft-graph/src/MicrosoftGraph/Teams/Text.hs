module MicrosoftGraph.Teams.Text (plainText, messageSize) where

import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Encoding
import qualified Data.ByteString as Bytes
import qualified Data.Attoparsec.Text as P
import Control.Applicative ((<|>))
import Data.Char (chr, isAlphaNum)
import Numeric (readHex)
import Text.Read (readMaybe)

-- This is a lossy text view, not an HTML renderer or sanitizer. Recognize tags,
-- quoted attributes and comments; retain text and separate markup boundaries.
-- Entity decoding happens after stripping so &lt;script&gt; stays literal text.
plainText :: Text -> Text
plainText input = Text.unwords . Text.words . entities . Text.concat . visible Nothing $
  either (const [Words input]) id (P.parseOnly (P.many' part <* P.endOfInput) input)
  where
    visible _ [] = []
    visible blocked (item:rest) = case (blocked,item) of
      (Just expected,Close name) | name == expected -> " " : visible Nothing rest
      (Just _,_) -> visible blocked rest
      (Nothing,Open name) | name `elem` ["script","style"] -> visible (Just name) rest
      (Nothing,Words value) -> value : visible Nothing rest
      _ -> " " : visible Nothing rest

data Part = Words Text | Open Text | Close Text | Markup

part :: P.Parser Part
part = comment <|> tag <|> (Words <$> P.takeWhile1 (/= '<')) <|> (Words . Text.singleton <$> P.anyChar)
  where
    comment = P.string "<!--" *> P.manyTill P.anyChar (P.string "-->") *> pure Markup
    tag = do
      _ <- P.char '<'
      closing <- (P.char '/' *> pure True) <|> pure False
      name <- Text.toLower <$> P.takeWhile1 isAlphaNum
      _ <- P.peekChar >>= \next -> case next of
        Just c | c `elem` [' ','\t','\n','\r','/','>'] -> pure ()
        _ -> fail "Not a tag"
      _ <- P.many' (quoted '"' <|> quoted '\'' <|> (P.satisfy (\c -> c /= '>' && c /= '"' && c /= '\'') *> pure ()))
      _ <- P.char '>'
      pure (if closing then Close name else Open name)
    quoted quote = P.char quote *> P.takeTill (== quote) *> P.char quote *> pure ()

entities :: Text -> Text
entities input = case Text.breakOn "&" input of
  (before,rest) | Text.null rest -> before
               | otherwise ->
      let after = Text.drop 1 rest
          (name,ending) = Text.breakOn ";" after
      in if Text.length name <= 12 && not (Text.null ending)
        then case decode name of
          Just value -> before <> value <> entities (Text.drop 1 ending)
          Nothing -> before <> "&" <> entities after
        else before <> "&" <> entities after
  where
    decode name = case lookup name [("amp","&"),("lt","<"),("gt",">"),("quot","\""),("apos","'"),("nbsp"," ")] of
      Just value -> Just value
      Nothing -> do
        digits <- Text.stripPrefix "#" name
        value <- case Text.uncons digits of
          Just (prefix,hex) | prefix == 'x' || prefix == 'X' -> case readHex (Text.unpack hex) of
            [(number,"")] -> Just number
            _ -> Nothing
          _ -> readMaybe (Text.unpack digits)
        if value > 0 && value <= (0x10ffff :: Integer) && not (value >= 0xd800 && value <= 0xdfff)
          then Just (Text.singleton (chr (fromInteger value))) else Nothing

messageSize :: Text -> Int
messageSize = Bytes.length . Encoding.encodeUtf8
