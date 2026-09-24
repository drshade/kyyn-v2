{-# LANGUAGE DataKinds, GADTs, LambdaCase, OverloadedStrings #-}
module Kyyn.Plumbing.Interpreter.SecretStore (runSecretStoreIO) where

import Control.Exception (IOException, try)
import qualified Data.ByteString as Bytes
import Data.Aeson (Value(String))
import Data.List (sort)
import qualified Data.Text.Encoding as Text
import Effectful (Eff, IOE, (:>), liftIO)
import Effectful.Dispatch.Dynamic (interpret)
import qualified Effectful.Exception as Exception
import Kyyn.Domain.DataType (Shape(Scalar), ScalarKind(TextScalar))
import qualified Kyyn.Domain.Failure as Failure
import Kyyn.Domain.Path (DirectoryScope, scopePath)
import Kyyn.Domain.Secret
import Kyyn.Plumbing.Capability.DhallHandling
import Kyyn.Plumbing.Capability.Failure (Failure, raiseFailure)
import Kyyn.Plumbing.Capability.SecretStore
import System.Directory (createDirectoryIfMissing, listDirectory, removeFile, renameFile)
import System.FilePath ((</>), takeExtension, dropExtension)
import System.IO (hClose, hSetBinaryMode)
import System.IO.Error (isDoesNotExistError)
import System.IO.Temp (withTempFile)

runSecretStoreIO
  :: (IOE :> es, Failure :> es, DhallHandling :> es)
  => DirectoryScope -> Eff (SecretStore : es) a -> Eff es a
runSecretStoreIO scope = interpret $ \_ -> \case
  ReadSecret name -> do
    let target = location name
    bytes <- native Failure.ReadFile target (optional (Bytes.readFile target))
    case bytes of
      Nothing -> pure (Left (SecretNotFound name))
      Just contents -> case Text.decodeUtf8' contents of
        Left _ -> corrupt target
        Right source -> do
          decoded <- decodeValue (Scalar TextScalar) source
          case decoded of
            Right (String value) -> pure (Right value)
            _ -> corrupt target
  WriteSecret name value -> do
    let target = location name
    encoded <- encodeValue (Scalar TextScalar) (String value)
    case encoded of
      Left _ -> storageFailure Failure.WriteFile target "Could not encode secret."
      Right document -> native Failure.WriteFile target $ do
        createDirectoryIfMissing True directory
        -- Establish the ignore rule before any temporary or final value exists.
        Bytes.writeFile (directory </> ".gitignore") "*\n"
        withTempFile directory ".pending-" $ \temporary handle -> do
          hSetBinaryMode handle True
          Bytes.hPut handle (Text.encodeUtf8 document)
          hClose handle
          renameFile temporary target
  ListSecretNames -> do
    entries <- native Failure.ListDirectory directory (optional (listDirectory directory))
    pure (sort [name | file <- maybe [] id entries, takeExtension file == ".dhall",
      Right name <- [secretName (dropExtension file)]])
  RemoveSecret name -> do
    result <- native Failure.WriteFile (location name) (optional (removeFile (location name)))
    pure (case result of Nothing -> False; Just () -> True)
  where
    directory = scopePath scope </> ".kyyn" </> "secrets"
    location name = directory </> secretNameText name ++ ".dhall"
    corrupt path = storageFailure Failure.ReadFile path "Invalid secret document; set the value again."

optional :: IO a -> IO (Maybe a)
optional action = do
  result <- try action
  case result of
    Right value -> pure (Just value)
    Left err | isDoesNotExistError err -> pure Nothing
             | otherwise -> ioError err

native :: (IOE :> es, Failure :> es) => Failure.StorageOperation -> FilePath -> IO a -> Eff es a
native operation path action = liftIO action `Exception.catch` \(_ :: IOException) ->
  storageFailure operation path "Could not access local secret storage."

storageFailure :: Failure :> es => Failure.StorageOperation -> FilePath -> String -> Eff es a
storageFailure operation path message =
  raiseFailure (Failure.StorageUnavailable (Failure.StorageDiagnostic operation path message))
