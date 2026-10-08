{-# LANGUAGE GADTs, LambdaCase, DataKinds #-}
module Kyyn.Porcelain.Interpreter.Delivery (runDelivery) where

import Control.Monad (unless)
import Data.Aeson (Value(..), encode, object, (.=), (.:), withObject)
import Data.Aeson.Types (Parser, parseEither)
import qualified Data.ByteString as Bytes
import qualified Data.ByteString.Lazy as Lazy
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import Effectful (Eff, (:>))
import Effectful.Dispatch.Dynamic (interpret)
import Effectful.Error.Static (catchError)
import Effectful.State.Static.Local (evalState, get, put)
import System.FilePath ((</>), takeDirectory, takeFileName)
import Kyyn.Domain.Contract (contractId, contractShape)
import Kyyn.Domain.Diagnostic (errorDiagnostic)
import Kyyn.Domain.Failure (OperationalFailure)
import Kyyn.Domain.Output (PublicationOutcome(..))
import Kyyn.Domain.Path (DirectoryScope, directoryScope, relativePath, scopePath)
import Kyyn.Domain.Value (CheckedValue(..))
import Kyyn.Plumbing.Capability.DhallHandling (DhallHandling, encodeValue)
import Kyyn.Plumbing.Capability.Failure (Failure)
import Kyyn.Plumbing.Capability.FileSystem (FileSystem, publishBytes)
import Kyyn.Plumbing.Capability.GuestExecution (GuestExecution, executeGuest)
import Kyyn.Plumbing.Capability.ProcessExecution (ProcessExit(..))
import Kyyn.Plumbing.Protocol.Frame (Frame(..), jsonFrame)
import Kyyn.Plumbing.Protocol.PluginMessages (PluginFrame(..), decodeFrameWith, encodeResponse, success)
import Kyyn.Porcelain.Capability.Delivery
import Kyyn.Porcelain.Capability.PluginPreparation (ConfiguredConnector(..), PreparedConnector(..))

runDelivery :: (GuestExecution :> es, FileSystem :> es, DhallHandling :> es, Failure :> es)
  => DirectoryScope -> Eff (Delivery : es) a -> Eff es a
runDelivery base = interpret $ \_ -> \case
  InvokeSink (ConfiguredConnector _ _ PreparedConnector{} _) _ _ ->
    pure (FailedBeforeDispatch (errorDiagnostic "output.sink-required" "A source connector cannot publish an output."))
  InvokeSink (ConfiguredConnector _ _ PreparedSinkConnector {configContract = configType,
    sinkInputContract = inputType,sinkOptionsContract = optionsType,sinkResultContract = resultType,sinkEntry = entry}
    (CheckedValue configId config)) (CheckedValue optionsId options) (CheckedValue inputId input) -> do
    let contracts = [(configType,configId,config),(optionsType,optionsId,options),(inputType,inputId,input)]
    checked <- mapM (\(contract,identity,value) -> if contractId contract /= identity
      then pure (Left [errorDiagnostic "output.contract" "Sink argument belongs to a different contract."])
      else encodeValue (contractShape contract) value) contracts
    case concat [diagnostics | Left diagnostics <- checked] of
      problem:_ -> pure (FailedBeforeDispatch problem)
      [] -> evalState (1 :: Integer,False) $ do
        let uncertain message = do
              (_,dispatched) <- get @(Integer,Bool)
              pure ((if dispatched then Uncertain else FailedBeforeDispatch) (errorDiagnostic "output.delivery" message))
            decode (Frame metadata body)
              | Bytes.null body = decodeFrameWith call metadata
              | otherwise = Left "Unexpected body in sink frame"
            respond frame = case decode frame of
              Right (HostRequest identity (path,content)) -> do
                (expected,dispatched) <- get @(Integer,Bool)
                if identity /= expected then pure Nothing else do
                  let target = scopePath base </> path
                  reply <- case (directoryScope (takeDirectory target),relativePath (takeFileName target)) of
                    (Right directory,Right file) | not (null path) && '\0' `notElem` path -> do
                      put (expected + 1,True)
                      result <- publishBytes directory file (Text.encodeUtf8 content)
                      pure (either rejection (success . String . Text.pack . const target) result)
                    _ -> put (expected + 1,dispatched) >> pure (rejection "Invalid output path")
                  pure (Just (jsonFrame (encodeResponse identity reply)))
              _ -> pure Nothing
        (do
          (lastFrame,ProcessExit status stderr) <- executeGuest entry (jsonFrame (Lazy.toStrict
            (encode (object ["config" .= config,"options" .= options,"input" .= input])))) respond
          if status /= 0 then uncertain ("Sink exited unsuccessfully: " ++ show stderr) else case decode lastFrame of
            Right (Completed result) -> case parseEither resultValue result of
              Left problem -> uncertain problem
              Right (Left (kind,message)) -> pure ((if kind == "Rejected" then RejectedByDestination else Uncertain)
                (errorDiagnostic "output.sink" message))
              Right (Right value) -> encodeValue (contractShape resultType) value >>= \case
                Left diagnostics -> uncertain ("Invalid sink result: " ++ show diagnostics)
                Right _ -> pure (Acknowledged (CheckedValue (contractId resultType) value))
            _ -> uncertain "Sink did not complete with a typed result")
          `catchError` \_ (failure :: OperationalFailure) -> uncertain (show failure)
  where
    call :: String -> String -> Value -> Parser (FilePath,Text.Text)
    call "files" "write" = withObject "file write" $ \fields -> (,) <$> fields .: "path" <*> fields .: "content"
    call _ _ = const (fail "Unsupported sink capability")
    rejection :: String -> Value
    rejection message = object ["tag" .= ("Left" :: String),"value" .= object
      ["kind" .= ("Rejected" :: String),"message" .= message]]
    resultValue :: Value -> Parser (Either (String,String) Value)
    resultValue = withObject "sink result" $ \fields -> do
      tag <- fields .: "tag"
      case tag :: String of
        "Right" -> Right <$> fields .: "value"
        "Left" -> fields .: "value" >>= withObject "sink error" (\details -> do
          kind <- details .: "kind"
          unless (kind `elem` ["Rejected","Uncertain" :: String]) (fail "Unknown sink error kind")
          Left . (kind,) <$> details .: "message")
        _ -> fail "Unknown sink result"
