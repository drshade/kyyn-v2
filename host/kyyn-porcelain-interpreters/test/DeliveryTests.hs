{-# LANGUAGE DataKinds, GADTs, TypeApplications #-}
module DeliveryTests (deliveryTests) where

import Control.Monad (unless)
import Data.Aeson (object, (.=), encode, Value(..))
import qualified Data.ByteString.Lazy as Lazy
import Effectful (Eff, runPureEff)
import Effectful.Dispatch.Dynamic (interpret, localSeqUnlift)
import Effectful.State.Static.Local (State, runState, modify)
import GuestFixture (fixtureProgram)
import Kyyn.Domain.Contract (checkContract, contractId)
import Kyyn.Domain.DataType (DataType(StringType))
import Kyyn.Domain.Output (PublicationOutcome(..))
import Kyyn.Domain.Path (directoryScope, scopedPath)
import Kyyn.Domain.Plugin (ConnectorName(..), ConnectorTypeName(..), BindingName(..))
import Kyyn.Domain.Value (CheckedValue(..))
import Kyyn.Types.SchemaMetadata (SchemaMetadata(..))
import Kyyn.Plumbing.Capability.FileSystem (FileSystem(..))
import Kyyn.Plumbing.Capability.GuestExecution (GuestExecution(..))
import Kyyn.Plumbing.Capability.ProcessExecution (ProcessExit(..))
import Kyyn.Plumbing.Protocol.Frame (Frame, jsonFrame)
import Kyyn.Plumbing.Interpreter.DhallHandling (runDhallHandling)
import Kyyn.Plumbing.Interpreter.Failure (runFailure)
import Kyyn.Porcelain.Capability.Delivery (invokeSink)
import Kyyn.Porcelain.Capability.PluginPreparation
import Kyyn.Porcelain.Interpreter.Delivery (runDelivery)

deliveryTests :: IO ()
deliveryTests = do
  let contract = either (error . show) id (checkContract StringType (SchemaMetadata [] [] []))
      value = CheckedValue (contractId contract) (String "text")
      program = fixtureProgram "not executed"
      sink = PreparedSinkConnector (ConnectorTypeName "File") contract program contract contract contract program value
      configured = ConfiguredConnector (ConnectorName "file") (BindingName "file") sink value
      scope = either error id (directoryScope "/kb")
      execute write exitCode result = runPureEff . runFailure . runDhallHandling . runState ([] :: [FilePath]) . files . guest write exitCode result $
        runDelivery scope (invokeSink configured value value)
      right = object ["tag" .= ("Right" :: String),"value" .= ("/kb/page.html" :: String)]
      wrong = object ["tag" .= ("Right" :: String),"value" .= True]
  case execute False 7 right of
    Right (FailedBeforeDispatch _,[]) -> pure ()
    other -> fail ("Pre-dispatch failure: " ++ show other)
  case execute True 7 right of
    Right (Uncertain _,["/kb/page.html"]) -> pure ()
    other -> fail ("Post-dispatch failure: " ++ show other)
  case execute True 0 wrong of
    Right (Uncertain _,["/kb/page.html"]) -> pure ()
    other -> fail ("Invalid response after write: " ++ show other)
  case execute True 0 right of
    Right (Acknowledged _,["/kb/page.html"]) -> pure ()
    other -> fail ("Successful publication: " ++ show other)
  putStrLn "Sink delivery distinguishes pre-dispatch failure, uncertain writes and typed acknowledgement."
  where
    guest :: Bool -> Int -> Value -> Eff (GuestExecution : es) a -> Eff es a
    guest write status value = interpret $ \env operation -> case operation of
      ExecuteCompiled{} -> error "Sink used one-shot execution"
      ExecuteGuest _ _ respond -> localSeqUnlift env $ \unlift -> do
        if write then do
          response <- unlift (respond (frame (object ["tag" .= ("HostRequest" :: String),"id" .= ("1" :: String),
            "capability" .= ("files" :: String),"method" .= ("write" :: String),"arguments" .= object
            ["path" .= ("page.html" :: String),"content" .= ("contents" :: String)]])))
          unless (maybe False (const True) response) (error "File request was not answered")
        else pure ()
        pure (frame (object ["tag" .= ("Completed" :: String),"result" .= value]),ProcessExit status "failure")
    frame :: Value -> Frame
    frame = jsonFrame . Lazy.toStrict . encode
    files :: Eff (FileSystem : State [FilePath] : es) a -> Eff (State [FilePath] : es) a
    files = interpret $ \_ operation -> case operation of
      PublishBytes scope path _ -> modify @[FilePath] (++ [scopedPath scope path]) >> pure (Right ())
      _ -> error "Sink used an unexpected filesystem operation"
