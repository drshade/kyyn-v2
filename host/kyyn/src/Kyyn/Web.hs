{-# LANGUAGE TemplateHaskell #-}
module Kyyn.Web (runServer, ViewSource(..)) where

import Control.Exception (IOException, bracket, displayException, try)
import Data.Aeson (ToJSON, Value(..), encode, eitherDecode, object)
import qualified Data.Aeson.KeyMap as Keys
import qualified Data.ByteString as Bytes
import qualified Data.ByteString.Char8 as Char8
import qualified Data.ByteString.Lazy as Lazy
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import Language.Haskell.TH.Syntax (addDependentFile, lift, runIO, loc_filename)
import qualified Language.Haskell.TH.Syntax as TH
import Network.HTTP.Types
import Network.HTTP.Types.Header (hAllow)
import Network.Mime (defaultMimeLookup)
import Network.Socket hiding (socket)
import qualified Network.Socket as Socket
import Network.Wai
import Network.Wai.Handler.Warp (defaultSettings, runSettingsSocket)
import System.FilePath ((</>), takeDirectory)
import System.IO (hFlush, stdout)
import Kyyn.Domain.Diagnostic (Diagnostic(..), errorDiagnostic)
import Kyyn.Domain.FileTree (FileTree, files)
import Kyyn.Domain.Path (relativeName, relativePath)
import Kyyn.Domain.View (ViewDefinition(..))
import qualified Kyyn.Surfaces.Result as Result

data ViewSource = ViewSource Value [ViewDefinition] FileTree

runServer :: Int -> IO (Either Result.Response ViewSource)
  -> (String -> Value -> IO (Value,Result.Response)) -> IO Result.Response
runServer port pages query = bracket (try @IOException acquire) (either (const (pure ())) close) $ \opened ->
  case opened of
    Left err -> pure (Result.refusal [errorDiagnostic "web.listen"
      ("Cannot listen on 127.0.0.1:" ++ show port ++ ": " ++ displayException err)])
    Right socket -> do
      address <- getSocketName socket
      let actual = case address of SockAddrInet n _ -> fromIntegral n :: Int; _ -> port
      putStrLn ("Serving http://127.0.0.1:" ++ show actual ++ "/kb/")
      hFlush stdout
      runSettingsSocket defaultSettings socket application
      pure (Result.success (object []) [])
  where
    acquire = do
      socket <- Socket.socket AF_INET Stream defaultProtocol
      result <- try @IOException $ do
        setSocketOption socket ReuseAddr 1
        bind socket (SockAddrInet (fromIntegral port) (tupleToHostAddress (127,0,0,1)))
        listen socket maxListenQueue
      case result of Left err -> close socket >> ioError err; Right () -> pure socket
    application request respond = do
      result <- try @IOException (route request)
      respond $ either (\err -> failure status500 "web.io" (displayException err)) id result
    route request
      | pathInfo request == [] = pure $ if requestMethod request == methodGet
          then responseLBS status302 [(hLocation,"/kb/"),noStore] "" else method "GET"
      | ["kb","queries",name] <- pathInfo request =
          if requestMethod request /= methodPost then pure (method "POST")
          else if fmap (Char8.map lower . Char8.takeWhile (/= ';')) (lookup hContentType (requestHeaders request)) /= Just "application/json"
            then pure (failure status415 "web.media-type" "Query requests require application/json")
          else do
            body <- strictRequestBody request
            case eitherDecode body of
              Left message -> pure (failure status400 "web.json" message)
              Right args -> do
                (context,result) <- query (Text.unpack name) args
                pure (jsonResponse (resultStatus result) context result)
      | requestMethod request /= methodGet = pure (method "GET")
      | otherwise = do
          selected <- pages
          pure $ case selected of
            Left result -> jsonResponse (resultStatus result) Null result
            Right (ViewSource context views tree) -> static request context views tree
    lower c | c >= 'A' && c <= 'Z' = toEnum (fromEnum c + 32)
            | otherwise = c

static :: Request -> Value -> [ViewDefinition] -> FileTree -> Response
static request context views tree = case pathInfo request of
  ["kb"] | rawPathInfo request == "/kb" -> responseLBS status302 [(hLocation,"/kb/"),noStore] ""
  ["kb"] -> index
  ["kb",""] -> index
  ["kb","kyyn.js"] -> content "text/javascript; charset=utf-8" $ Text.encodeUtf8 $
    Text.replace "__KYYN_CONTEXT__" (jsonText context) $
    Text.replace "__KYYN_VIEWS__" (jsonText [name | ViewDefinition name _ _ <- views]) script
  "kb":"views":name:rest -> case [page | ViewDefinition actual _ page <- views, Text.pack actual == name] of
    [_] | null rest && not ("/" `Bytes.isSuffixOf` rawPathInfo request) ->
      responseLBS status302 [(hLocation,rawPathInfo request <> "/" <> rawQueryString request),noStore] ""
    [page] ->
      let asset = if null rest || rest == [""] then Right page
            else relativePath (takeDirectory (relativeName page) ++ "/" ++ Text.unpack (Text.intercalate "/" rest))
      in case asset >>= \path -> maybe (Left "Missing view asset") (Right . (path,)) (lookup path (files tree)) of
        Left message -> failure status404 "view.asset" message
        Right (path,bytes) -> content (defaultMimeLookup (Text.pack (relativeName path))) bytes
    _ -> failure status404 "view.unknown" "No declared view with that name"
  _ -> failure status404 "web.route" "Unknown route"
  where
    content mime bytes = responseLBS status200 ((hContentType,mime):noStore:contextHeaders context) (Lazy.fromStrict bytes)
    index = content "text/html; charset=utf-8" . Text.encodeUtf8 $
      "<!doctype html><meta charset=utf-8><title>Knowledge base</title><h1>Knowledge base views</h1><p>" <>
      escape (contextLabel context) <> "</p>" <> (if null views then "<p>No views are declared.</p>" else "") <> "<ul>" <> Text.concat
      ["<li><a href=\"/kb/views/" <> Text.decodeUtf8 (urlEncode True (Text.encodeUtf8 (Text.pack name))) <>
        "/\">" <> escape (Text.pack name) <> "</a> — " <> escape (Text.pack description) <> "</li>" |
        ViewDefinition name description _ <- views] <> "</ul>"

contextLabel :: Value -> Text.Text
contextLabel (Object fields) =
  let revision = case Keys.lookup "revision" fields of Just (String value) -> Text.take 8 value; _ -> "unknown"
  in case Keys.lookup "evolution" fields of
    Just (String value) -> "Draft " <> value <> " (base " <> revision <> ")"
    _ -> "Accepted revision " <> revision
contextLabel _ = "Knowledge base"

jsonText :: ToJSON a => a -> Text.Text
jsonText = Text.decodeUtf8 . Lazy.toStrict . encode

escape :: Text.Text -> Text.Text
escape = Text.concatMap (\c -> case c of '&' -> "&amp;"; '<' -> "&lt;"; '>' -> "&gt;"; '"' -> "&quot;"; '\'' -> "&#39;"; _ -> Text.singleton c)

contextHeaders :: Value -> ResponseHeaders
contextHeaders (Object fields) =
  [(name,Text.encodeUtf8 value) | (key,name) <- [("revision","X-Kyyn-Revision"),("evolution","X-Kyyn-Evolution")],
    Just (String value) <- [Keys.lookup key fields]]
contextHeaders _ = []

noStore :: Header
noStore = (hCacheControl,"no-store")
method :: Bytes.ByteString -> Response
method allowed = responseLBS status405 [(hAllow,allowed),(hContentType,"application/json"),noStore]
  (encode (Result.responseJson (Result.refusal [errorDiagnostic "web.method" "Unsupported method"])))
failure :: Status -> String -> String -> Response
failure status code message = jsonResponse status Null (Result.refusal [errorDiagnostic code message])
jsonResponse :: Status -> Value -> Result.Response -> Response
jsonResponse status context result = responseLBS status [(hContentType,"application/json"),noStore] $
  encode $ case Result.responseJson result of Object value -> Object (Keys.insert "context" context value); value -> value
resultStatus :: Result.Response -> Status
resultStatus (Result.Response outcome _ _ diagnostics)
  | outcome == Result.Succeeded = status200
  | any (`elem` ["query.unknown","view.unknown","view.asset"]) codes = status404
  | any (`elem` ["evolution.no-candidate","web.accepted"]) codes = status409
  | outcome == Result.Failed = status500
  | otherwise = status400
  where codes = [code | Diagnostic _ code _ _ <- diagnostics]

script :: Text.Text
script = Text.pack $(do
  source <- loc_filename <$> TH.location
  let path = takeDirectory source </> "../../web/kyyn.js"
  addDependentFile path
  runIO (readFile path) >>= lift)
