{-# LANGUAGE DataKinds, GADTs, LambdaCase, OverloadedStrings #-}
module Main (main) where

import Control.Monad (unless, forM_)
import qualified Data.ByteString.Char8 as Bytes
import Data.List (isInfixOf, sort)
import Data.Text (Text)
import Effectful (Eff, IOE, runEff, runPureEff, (:>))
import Effectful.Dispatch.Dynamic (reinterpret)
import Effectful.State.Static.Local (evalState, get, modify)
import Kyyn.Domain.Path (directoryScope)
import Kyyn.Domain.Secret
import Kyyn.Domain.Failure (OperationalFailure)
import Kyyn.Plumbing.Capability.Failure (Failure)
import Kyyn.Plumbing.Capability.DhallHandling (DhallHandling)
import Kyyn.Plumbing.Capability.SecretStore
import Kyyn.Plumbing.Interpreter.SecretStore (runSecretStoreIO)
import Kyyn.Plumbing.Interpreter.DhallHandling (runDhallHandling)
import Kyyn.Plumbing.Interpreter.Failure (runFailure)
import System.Directory (createDirectory, listDirectory, doesPathExist)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)

main :: IO ()
main = do
  forM_ ["", "..", "a.b", "../key", "a/b", "a\\b", "a b", "é"] $ \name ->
    assert "invalid name accepted" (case secretName name of Left _ -> True; _ -> False)
  let key = named "JEV_TOKEN"
      other = named "another-key"
  assert "recording handler" (runPureEff (recording (journey key other)))
  withSystemTempDirectory "kyyn-secrets-" $ \directory -> do
    let scope = either error id (directoryScope directory)
        run :: Eff '[SecretStore, DhallHandling, Failure, IOE] a -> IO (Either OperationalFailure a)
        run action = runEff . runFailure . runDhallHandling . runSecretStoreIO scope $ action
        store = directory </> ".kyyn/secrets"
    result <- run (journey key other)
    assert "native handler" (result == Right True)
    ignored <- Bytes.readFile (store </> ".gitignore")
    assert "ignore installed" (ignored == "*\n")
    assert "Dhall file" . (== "\"replacement\"\n") =<< Bytes.readFile (store </> "JEV_TOKEN.dhall")
    createDirectory (directory </> "second")
    let second = either error id (directoryScope (directory </> "second"))
    missing <- runEff . runFailure . runDhallHandling . runSecretStoreIO second $ readSecret key
    assert "scopes do not share values" (missing == Right (Left (SecretNotFound key)))
    assert "read does not create store" . not =<< doesPathExist (directory </> "second/.kyyn")
    forM_ ["\"secret-that-must-not-leak\" : Natural", "env:SECRET", "./outside", "\255"] $ \malformed -> do
      Bytes.writeFile (store </> "JEV_TOKEN.dhall") malformed
      failure <- run (readSecret key)
      assert "invalid document not a missing secret" (case failure of Left _ -> True; _ -> False)
      assert "sanitized decode failure" (not ("secret-that-must-not-leak" `isInfixOf` show failure))
    _ <- run (writeSecret key "repaired")
    assert "corrupt file can be repaired" . (== Right (Right "repaired")) =<< run (readSecret key)
    createDirectory (store </> "blocked.dhall")
    failure <- run (writeSecret (named "blocked") "secret-that-must-not-leak")
    assert "replacement failure reported" (case failure of Left _ -> True; _ -> False)
    entries <- listDirectory store
    assert "failed replacement temp cleaned" (sort entries == [".gitignore", "JEV_TOKEN.dhall", "blocked.dhall"])
    assert "write failure sanitized" (not ("secret-that-must-not-leak" `isInfixOf` show failure))
  putStrLn "Secret store: recording, Dhall/native, isolation, invalid input, sanitized failure and replacement checks passed."

journey :: SecretStore :> es => SecretName -> SecretName -> Eff es Bool
journey key other = do
  initial <- listSecretNames
  missing <- readSecret key
  absent <- removeSecret key
  let text = "private \"quote\" ${interpolation}\\\n雪"
  writeSecret key text
  loaded <- readSecret key
  writeSecret other ""
  empty <- readSecret other
  names <- listSecretNames
  writeSecret key "replacement"
  replaced <- readSecret key
  removed <- removeSecret other
  again <- removeSecret other
  pure (null initial && missing == Left (SecretNotFound key) && not absent && loaded == Right text
    && empty == Right "" && names == sort [key,other] && replaced == Right "replacement" && removed && not again)

recording :: Eff (SecretStore : es) a -> Eff es a
recording = reinterpret (evalState ([] :: [(SecretName, Text)])) $ \_ -> \case
  ReadSecret name -> maybe (Left (SecretNotFound name)) Right . lookup name <$> get
  WriteSecret name value -> modify ((:) (name,value) . filter ((/= name) . fst))
  ListSecretNames -> sort . map fst <$> get @[(SecretName, Text)]
  RemoveSecret name -> do
    present <- any ((== name) . fst) <$> get @[(SecretName, Text)]
    modify @[(SecretName, Text)] (filter ((/= name) . fst))
    pure present

named :: String -> SecretName
named = either error id . secretName
assert :: String -> Bool -> IO ()
assert label condition = unless condition (fail label)
