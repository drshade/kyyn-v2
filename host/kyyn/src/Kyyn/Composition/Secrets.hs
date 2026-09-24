{-# LANGUAGE DataKinds, OverloadedStrings #-}
module Kyyn.Composition.Secrets (executeSecrets) where

import Control.Exception (IOException, bracket, try)
import Data.Aeson (object, (.=))
import qualified Data.ByteString.Char8 as Bytes
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import Effectful (runEff)
import Kyyn.Domain.Diagnostic (errorDiagnostic)
import Kyyn.Domain.Path (directoryScope)
import Kyyn.Domain.Secret (secretNameText, SecretError(..))
import qualified Kyyn.Plumbing.Capability.SecretStore as Store
import Kyyn.Plumbing.Interpreter.SecretStore (runSecretStoreIO)
import Kyyn.Plumbing.Interpreter.DhallHandling (runDhallHandling)
import Kyyn.Plumbing.Interpreter.Failure (runFailure)
import qualified Kyyn.Surfaces.Cli as Cli
import Kyyn.Surfaces.Result
import System.Directory (canonicalizePath, doesDirectoryExist)
import System.IO (stdin, stderr, hIsTerminalDevice, hGetEcho, hSetEcho, hPutStr, hPutStrLn, hFlush)

executeSecrets :: FilePath -> Cli.SecretCommand -> IO Response
executeSecrets selected command = do
  directory <- canonicalizePath selected
  exists <- doesDirectoryExist directory
  case directoryScope directory of
    Left message -> pure (refusal [errorDiagnostic "kb.path" message])
    Right _ | not exists -> pure (refusal [errorDiagnostic "kb.directory" "Select an existing KB directory with --kb PATH."])
    Right scope -> do
      input <- case command of
        Cli.SetSecret _ argument -> fmap Just <$> readInput argument
        _ -> pure (Right Nothing)
      case input of
        Left diagnostic -> pure (refusal [errorDiagnostic "secret.input" diagnostic])
        Right value -> do
          result <- runEff . runFailure . runDhallHandling . runSecretStoreIO scope $ case command of
            Cli.ListSecrets -> do
              names <- map secretNameText <$> Store.listSecretNames
              pure (success (object ["names" .= names]) (if null names then ["No local secrets."] else names))
            Cli.ShowSecret name -> do
              loaded <- Store.readSecret name
              pure $ case loaded of
                Left (SecretNotFound _) -> refusal [errorDiagnostic "secret.not-found"
                  ("No secret named " ++ secretNameText name ++ "; use secret set to configure it.")]
                Right contents -> let masked = maskSecret contents in
                  success (object ["name" .= secretNameText name, "masked" .= masked])
                    [secretNameText name ++ ": " ++ Text.unpack masked]
            Cli.RemoveSecret name -> do
              removed <- Store.removeSecret name
              pure (success (object ["name" .= secretNameText name, "removed" .= removed])
                [(if removed then "Removed " else "No secret named ") ++ secretNameText name])
            Cli.SetSecret name _ -> case value of
              Just contents -> do
                Store.writeSecret name contents
                pure (success (object ["name" .= secretNameText name]) ["Stored " ++ secretNameText name])
              Nothing -> pure (refusal [errorDiagnostic "secret.input" "No value supplied; nothing stored."])
          pure (either operationalFailure id result)

readInput :: Maybe Cli.SecretArgument -> IO (Either String Text)
readInput argument = do
  result <- try @IOException $ case argument of
    Just (Cli.SecretArgument value) -> pure (Right (Text.pack value))
    Nothing -> do
      terminal <- hIsTerminalDevice stdin
      bytes <- if terminal
        then bracket
          (do previous <- hGetEcho stdin; hSetEcho stdin False; pure previous)
          (\previous -> hSetEcho stdin previous >> hPutStrLn stderr "")
          (\_ -> hPutStr stderr "Secret value: " >> hFlush stderr >> Bytes.hGetLine stdin)
        else Bytes.hGetContents stdin
      pure $ case Text.decodeUtf8' bytes of
        Left _ -> Left "Input must be UTF-8; nothing stored."
        Right value -> Right (if terminal then value else trimFinalNewline value)
  pure $ case result of
    Left _ -> Left "Could not read secret input; nothing stored."
    Right (Left message) -> Left message
    Right (Right value) | Text.null value -> Left "Value is empty; nothing stored."
                        | otherwise -> Right value

trimFinalNewline :: Text -> Text
trimFinalNewline value = case Text.stripSuffix "\n" value of
  Nothing -> value
  Just line -> maybe line id (Text.stripSuffix "\r" line)

maskSecret :: Text -> Text
maskSecret value =
  let size = Text.length value
      prefix = if size > 8 then Text.take 4 value else ""
  in prefix <> Text.replicate (size - Text.length prefix) "*"
