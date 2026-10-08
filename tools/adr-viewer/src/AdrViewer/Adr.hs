-- | Pure readings of ADR text: anchors, sections and titles, plus the code
-- identifiers that anchors are matched against.
--
-- An anchor is an identifier an ADR names in backticks or fenced code: a
-- CamelCase name with at least two humps, a capitalised name of six or more
-- characters, or a lowercase function with a signature. Generic names are
-- excluded because they say nothing about a specific decision.
{-# LANGUAGE OverloadedStrings #-}
module AdrViewer.Adr
  ( anchorsIn, sections, titleOf, identifiers, isCodePath, adrFileId
  ) where

import Data.Char (isAlphaNum, isAsciiLower, isAsciiUpper, isDigit, isSpace)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as T

stopList :: Set Text
stopList = Set.fromList
  [ "String", "Text", "Maybe", "Either", "Integer", "Double", "Boolean", "Options"
  , "Schema", "Failure", "Program", "Result", "Value", "Error", "Unit", "Natural"
  , "Optional", "Record", "Object", "Number", "Request", "Response", "Config" ]

anchorsIn :: Text -> Set Text
anchorsIn text = Set.filter (`Set.notMember` stopList) (Set.unions (spanAnchors <> sigAnchors))
  where
    blocks = fences text
    spanAnchors = map typeAnchors (backticks text <> blocks)
    sigAnchors = map signatures blocks
    typeAnchors span' = Set.fromList [w | w <- wordTokens span', camel w || longType w]

-- | Inline backtick spans, scanning like a regex: an unclosed backtick is skipped.
backticks :: Text -> [Text]
backticks t = case T.breakOn "`" t of
  (_, rest) | T.null rest -> []
  (_, rest) ->
    let body = T.drop 1 rest
        (inside, after) = T.break (\c -> c == '`' || c == '\n') body
    in if not (T.null inside) && T.isPrefixOf "`" after
         then inside : backticks (T.drop 1 after)
         else backticks body

-- | Bodies of fenced blocks: from a line starting with three backticks to the next.
fences :: Text -> [Text]
fences = go . T.lines
  where
    go ls = case break opener ls of
      (_, []) -> []
      (_, _ : rest) -> case break opener rest of
        (body, _ : after) -> T.unlines body : go after
        (_, []) -> []
    opener = T.isPrefixOf "```"

-- | Maximal runs of word characters, as a regex @\\b@ would delimit them.
wordTokens :: Text -> [Text]
wordTokens = filter (not . T.null) . T.split (not . wordChar)
  where wordChar c = isAlphaNum c || c == '_'

camel :: Text -> Bool
camel w = case T.uncons w of
  Just (c, rest) | isAsciiUpper c -> humps (0 :: Int) rest
  _ -> False
  where
    -- First hump needs at least one lowercase/digit; later humps may be bare capitals.
    humps n r = case T.span lowerOrDigit r of
      (low, more) | n == 0 && T.null low -> False
                  | T.null more -> n >= 1
                  | otherwise -> case T.uncons more of
                      Just (c, rest) | isAsciiUpper c -> humps (n + 1) rest
                      _ -> False
    lowerOrDigit c = isAsciiLower c || isDigit c

longType :: Text -> Bool
longType w = case T.uncons w of
  Just (c, rest) -> isAsciiUpper c && T.length rest >= 5 && T.all asciiAlnum rest
  Nothing -> False
  where asciiAlnum c = isAsciiUpper c || isAsciiLower c || isDigit c

-- | @name ::@ at the start of a line inside a fenced block. The @::@ may follow on
-- a later line, as in a signature broken after its name.
signatures :: Text -> Set Text
signatures block = Set.fromList
  [ name | (line, later) <- zip ls (drop 1 (iterate (drop 1) ls))
  , let (name, rest) = T.span asciiAlnum (T.stripStart line)
  , Just (c, more) <- [T.uncons name], isAsciiLower c, T.length more >= 4
  , "::" `T.isPrefixOf` T.stripStart (T.unwords (rest : takeWhileBlank rest later)) ]
  where
    ls = T.lines block
    asciiAlnum c = isAsciiUpper c || isAsciiLower c || isDigit c
    -- Continue past the name's line only while everything so far is whitespace.
    takeWhileBlank rest later
      | T.all isSpace rest = case dropWhile (T.all isSpace) later of
          (next : _) -> [next]
          [] -> []
      | otherwise = []

-- | Heading path to body, splitting on @##@ and @###@ headings.
sections :: Text -> Map Text Text
sections text = finish (foldl step (["(preamble)"], [], Map.empty) (T.lines text))
  where
    step (path, buf, acc) line = case heading line of
      Just (level, title) ->
        let parent = if level == 3 then take 1 path else []
            parent' = if level == 3 && null parent then ["?"] else parent
        in (parent' <> [title], [], flush path buf acc)
      Nothing -> (path, line : buf, acc)
    finish (path, buf, acc) = flush path buf acc
    flush path buf = Map.insert (T.intercalate " / " path) (T.intercalate "\n" (reverse buf))
    heading line =
      let (hashes, rest) = T.span (== '#') line
          level = T.length hashes
      in if level `elem` [2, 3] && not (T.null rest) && isSpace (T.head rest)
           then Just (level, T.strip rest) else Nothing

titleOf :: Text -> Maybe Text
titleOf text = case [T.strip (T.drop 2 l) | l <- T.lines text, "# " `T.isPrefixOf` l] of
  (t : _) -> Just t
  [] -> Nothing

-- | Identifier tokens in source code, matched against the anchor universe.
identifiers :: Text -> Set Text
identifiers = Set.fromList . go
  where
    go t = case T.dropWhile (not . start) t of
      r | T.null r -> []
        | otherwise -> let (w, rest) = T.span inner r in w : go rest
    start c = isAsciiUpper c || isAsciiLower c || c == '_'
    inner c = start c || isDigit c || c == '\''

-- | Code is anything outside the architecture and docs trees that is not Markdown.
isCodePath :: Text -> Bool
isCodePath p = not (any (`T.isPrefixOf` p) ["architecture/", "docs/"]) && not (".md" `T.isSuffixOf` p)

-- | @architecture/adr/0014-evidence.md@ to @0014@; the template is not an ADR.
adrFileId :: Text -> Maybe Text
adrFileId p = do
  name <- T.stripPrefix "architecture/adr/" p
  let (digits, rest) = T.splitAt 4 name
  if T.length digits == 4 && T.all isDigit digits && "-" `T.isPrefixOf` rest
       && ".md" `T.isSuffixOf` rest && not ("/" `T.isInfixOf` rest) && digits /= "0000"
    then Just digits else Nothing
