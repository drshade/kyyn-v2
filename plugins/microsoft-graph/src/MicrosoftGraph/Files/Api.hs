{-# LANGUAGE OverloadedStrings #-}
module MicrosoftGraph.Files.Api (listing, itemUrl, field, optional, shareToken) where
import Control.Monad.Trans.Except (ExceptT(..), runExceptT, throwE)
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Encoding
import qualified Data.ByteString as Bytes
import Data.List (group, sort, sortOn)
import Kyyn.Plugin.Host
import MicrosoftGraph.Config (graphApiBase)
import MicrosoftGraph.Files.Types
import qualified MicrosoftGraph.Files.Config as Config
import qualified MicrosoftGraph.Json as Json
import qualified MicrosoftGraph.Http as Http
import Text.JSON.Types (JSValue(..), fromJSObject)

field :: Text -> JSValue -> Either Text Text
field key value = do
  result <- Json.member key value >>= Json.text
  if Text.null result then Left ("Empty Graph field: " <> key) else Right result

optional :: Text -> JSValue -> JSValue
optional key (JSObject values) = maybe JSNull id (lookup (Text.unpack key) (fromJSObject values))
optional _ _ = JSNull

itemUrl :: Text -> Text -> Text
itemUrl drive item = graphApiBase <> "drives/" <> Json.escape drive <> "/items/" <> Json.escape item

document :: Text -> Text -> Acquisition payload (Either Text JSValue)
document token url
  | not (graphApiBase `Text.isPrefixOf` url) = pure (Left "Unexpected Graph Files pagination URL")
  | otherwise = fmap (>>= \response -> Http.requireSuccess response >>= Json.parse)
      (Http.send (HttpRequest "GET" url [("Authorization","Bearer " <> token)] ""))

collection :: Text -> Text -> Acquisition payload (Either Text [JSValue])
collection token = runExceptT . pages []
  where
    pages seen url
      | url `elem` seen = throwE "Graph Files pagination repeated a page"
      | otherwise = do
          value <- ExceptT (document token url)
          entries <- either throwE pure (Json.member "value" value >>= Json.array)
          next <- either throwE pure (Json.optionalText "@odata.nextLink" value)
          rest <- maybe (pure []) (pages (url:seen)) next
          pure (entries ++ rest)

-- No hierarchy survives this invocation: every fetch resolves and walks anew.
listing :: Text -> FilesConfig -> Acquisition FilePayload (Either Text [(Text,Text,Text,JSValue)])
listing token (FilesConfig _ scope path globs) = runExceptT $ do
  base <- case scope of
    SiteLibrary site library -> do
      drives <- ExceptT (collection token (graphApiBase <> "sites/" <> Json.escape site <> "/drives"))
      names <- either throwE pure (mapM (\v -> (,) <$> field "id" v <*> field "name" v) drives)
      drive <- case [key | (key,name) <- names, key == library || name == library] of
        [key] -> pure key
        [] -> throwE "SharePoint library was not found"
        _ -> throwE "SharePoint library name is ambiguous; use its drive ID"
      pure (graphApiBase <> "drives/" <> Json.escape drive <> "/root")
    OneDrive user -> pure (graphApiBase <> (if user == "me" then "me" else "users/" <> Json.escape user) <> "/drive/root")
    SharedUrl url -> pure (graphApiBase <> "shares/" <> shareToken url <> "/driveItem")
  root <- ExceptT (document token base)
  drive <- either throwE pure (Json.member "parentReference" root >>= field "driveId")
  rootId <- either throwE pure (field "id" root)
  selected <- if Text.null path then pure root else do
    if optional "folder" root == JSNull then throwE "Configured path requires a folder scope" else pure ()
    ExceptT (document token (itemUrl drive rootId <> ":/" <> Text.intercalate "/" (map Json.escape (Text.splitOn "/" path))))
  (_,rows) <- walk drive "" [] selected
  let identities = sort [key | (key,_,_,_) <- rows]
  if any ((>1) . length) (group identities) then throwE "Graph Files listing repeated a file identity" else pure ()
  pure (sortOn (\(key,_,_,_) -> key) rows)
  where
    walk drive prefix seen value = do
      key <- either throwE pure (field "id" value)
      name <- either throwE pure (field "name" value)
      if Text.any (== '/') name || name `elem` [".",".."] then throwE "Invalid Graph file name" else pure ()
      if optional "remoteItem" value /= JSNull then throwE "Remote shortcuts are unsupported; select the target drive or sharing URL directly" else pure ()
      let relative = if Text.null prefix then name else prefix <> "/" <> name
          identity = Json.escape drive <> "/" <> Json.escape key
      if optional "file" value /= JSNull then
        pure (seen, [(identity,drive,relative,value) | Config.matches globs relative])
      else if optional "folder" value /= JSNull then do
        if identity `elem` seen then throwE "Graph Files listing repeated a folder identity" else pure ()
        children <- ExceptT (collection token (itemUrl drive key <> "/children"))
        -- The selected folder's own name is excluded from relative paths.
        walkChildren drive (if null seen then "" else relative) (identity:seen) children
      else throwE "Unsupported Graph item: expected an ordinary file or folder"
    walkChildren _ _ seen [] = pure (seen,[])
    walkChildren drive prefix seen (value:rest) = do
      (visited,rows) <- walk drive prefix seen value
      (final,more) <- walkChildren drive prefix visited rest
      pure (final,rows ++ more)

-- Graph's specified unpadded base64url encoding over UTF-8 sharing URLs.
shareToken :: Text -> Text
shareToken = ("u!" <>) . Text.pack . encode . map fromIntegral . Bytes.unpack . Encoding.encodeUtf8
  where
    alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
    at n = alphabet !! n
    encode (a:b:c:rest) = at (a `div` 4) : at ((a `mod` 4)*16+b `div` 16) :
      at ((b `mod` 16)*4+c `div` 64) : at (c `mod` 64) : encode rest
    encode [a,b] = [at (a `div` 4),at ((a `mod` 4)*16+b `div` 16),at ((b `mod` 16)*4)]
    encode [a] = [at (a `div` 4),at ((a `mod` 4)*16)]
    encode [] = []
