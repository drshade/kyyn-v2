{-# LANGUAGE GADTs #-}
module Kyyn.Plumbing.Interpreter.HttpTransport (runHttpTransportIO, runHttpTransportWith) where

import Control.Exception (try)
import Data.Char (ord)
import qualified Data.ByteString.Char8 as Bytes
import qualified Data.ByteString.Lazy as Lazy
import qualified Data.CaseInsensitive as CI
import Data.String (fromString)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import Effectful (Eff, IOE, (:>), liftIO)
import Effectful.Dispatch.Dynamic (interpret)
import Kyyn.Plumbing.Capability.HttpTransport
import qualified Network.HTTP.Client as Http
import Network.HTTP.Client.TLS (tlsManagerSettings)
import Network.HTTP.Types.Status (statusCode)

runHttpTransportIO :: IOE :> es => Eff (HttpTransport : es) a -> Eff es a
runHttpTransportIO action = do
  manager <- liftIO (Http.newManager tlsManagerSettings { Http.managerRetryableException = const False })
  runHttpTransportWith (\request -> do
    response <- Http.httpLbs request manager
    pure (statusCode (Http.responseStatus response),
      [(Bytes.unpack (CI.original name), Bytes.unpack value) | (name,value) <- Http.responseHeaders response],
      Http.responseBody response)) action

runHttpTransportWith :: IOE :> es
  => (Http.Request -> IO (Int, [(String,String)], Lazy.ByteString))
  -> Eff (HttpTransport : es) a -> Eff es a
runHttpTransportWith transport = interpret $ \_ (SendHttp (HttpRequest method url headers body)) -> do
  parsed <- if validToken (Text.unpack method) && all (\(name,value) -> validHeader (Text.unpack name,Text.unpack value)) headers
    then liftIO (try @Http.HttpException (Http.parseRequest (Text.unpack url)))
    else pure (Left (Http.InvalidUrlException "" "Invalid method or headers"))
  case parsed of
    Left _ -> pure (Left InvalidHttpRequest)
    Right base -> do
      let request = base
            { Http.method = Text.encodeUtf8 method
            , Http.requestHeaders = [(fromString (Text.unpack name), Text.encodeUtf8 value) | (name,value) <- headers]
            , Http.requestBody = Http.RequestBodyBS (Text.encodeUtf8 body)
            , Http.redirectCount = 0, Http.checkResponse = \_ _ -> pure () }
      response <- liftIO (try @Http.HttpException (transport request))
      pure $ case response of
        Left exception -> Left (transportError exception)
        Right (status,fields,bytes) -> case Text.decodeUtf8' (Lazy.toStrict bytes) of
          Left _ -> Left InvalidHttpResponse
          Right text -> Right (HttpResponse status [(Text.pack name,Text.pack value) | (name,value) <- fields] text)

transportError :: Http.HttpException -> HttpError
transportError (Http.InvalidUrlException _ _) = InvalidHttpRequest
transportError (Http.HttpExceptionRequest _ cause) = case cause of
  Http.ConnectionTimeout -> HttpTimedOut
  Http.ResponseTimeout -> HttpTimedOut
  Http.ConnectionFailure _ -> HttpConnectionFailed
  Http.ConnectionClosed -> HttpConnectionFailed
  Http.InvalidRequestHeader _ -> InvalidHttpRequest
  _ -> HttpUnavailable

validToken :: String -> Bool
validToken value = not (null value) && all (\c ->
  c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' ||
  c `elem` "!#$%&'*+-.^_`|~") value

validHeader :: (String,String) -> Bool
validHeader (name,value) = validToken name && all (\c -> c == '\t' || ord c >= 32 && ord c /= 127) value
