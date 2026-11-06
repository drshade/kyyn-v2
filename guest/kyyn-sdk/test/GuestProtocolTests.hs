-- A real subprocess describes and invokes the same compiled fixture through the
-- host frame codec. Nix derivation/source capture is tested separately.
{-# LANGUAGE DeriveAnyClass, DerivingStrategies, DeriveGeneric, OverloadedStrings, TypeApplications, OverloadedRecordDot #-}
module Main (main) where

import Control.Monad (unless, forM_)
import Data.Aeson (Value(..), object, (.=), encode, eitherDecodeStrict')
import qualified Data.Aeson.KeyMap as Keys
import qualified Data.ByteString.Char8 as Bytes
import qualified Data.ByteString.Lazy as Lazy
import Data.Fixed (Fixed, E2)
import Data.Functor.Identity (runIdentity)
import GHC.Generics (Generic)
import System.Environment (getArgs, getExecutablePath)
import System.Exit (ExitCode(..))
import System.Process (readProcessWithExitCode)
import Kyyn.Schema
import Kyyn.Types.Query (Query, CollectionBinding(..), readCollection)
import Kyyn.Types.Diagnostic (ValidationReport(..))
import qualified Kyyn.Types.Contract as D
import qualified Kyyn.Types.Guest as G
import Kyyn.Runtime.Guest
import qualified Kyyn.Plumbing.Protocol.Frame as Frame

data Item = Item { amount :: Fixed E2 } deriving stock (Generic) deriving anyclass (Contract)
data Root = Root { items :: [Fact Item] } deriving stock (Generic) deriving anyclass (Contract)

annotations :: SchemaMetadata
annotations = SchemaMetadata [] [] [CollectionDecl "items" "items" []]

total :: () -> Query Root (Fixed E2)
total () = do
  values <- readCollection (CollectionBinding "items" (\root -> root.items))
  pure (sum [item.amount | Fact _ item <- values])

guest :: IO ()
guest = runGuest []
  [validationEntry @Root annotations ["GuestProtocolTests.hs"] (const (ValidationReport [])),
   queryEntry @Root "total" annotations ["GuestProtocolTests.hs"] total]

main :: IO ()
main = do
  args <- getArgs
  if args == ["--guest"] then guest else check

check :: IO ()
check = do
  executable <- getExecutablePath
  descriptionValue <- invoke executable (object ["operation" .= ("describe" :: String)])
  description <- right (eitherDecodeStrict' (Lazy.toStrict (encode descriptionValue)) :: Either String G.GuestDescription)
  unless (description.protocol == G.protocolIdentity) (fail "Wrong protocol identity")
  unless (map G.entryName description.entries == ["validate","total"]) (fail "Wrong registered entries")
  forM_ description.entries $ \entry -> forM_ entry.entryContracts $ \(_,selected) ->
    unless (selected.identity == D.fingerprint (D.contractIdentity selected.structure selected.metadata))
      (fail "Guest description fingerprint disagrees")
  let root = object ["items" .= [fact "a" "12.34", fact "b" "-2.34"]]
      fact ident amount = object ["id" .= (ident :: String), "value" .= object ["amount" .= (amount :: String)]]
      request name argument = object ["operation" .= ("invoke" :: String), "entry" .= (name :: String), "argument" .= argument]
  report <- invoke executable (request "validate" root)
  unless (report == Array mempty) (fail "Validation did not run")
  result <- invoke executable (request "total" (object ["root" .= root,"arguments" .= object []]))
  case result of
    Object fields -> unless (Keys.lookup "result" fields == Just (String "10")) (fail "Exact sum changed")
    _ -> fail "Invalid query result"
  forM_ [request "missing" root,
    request "validate" (object ["items" .= [fact "a" "12.345"]]),
    object ["operation" .= ("describe" :: String), "argument" .= root]] $ \requestValue -> do
      (status,_,_) <- call executable requestValue
      unless (status /= ExitSuccess) (fail "Malformed invocation accepted")
  putStrLn "Compiled guest describe/invoke and rejection checks passed."

call :: FilePath -> Value -> IO (ExitCode,String,String)
call executable value = readProcessWithExitCode executable ["--guest"]
  (Bytes.unpack (Bytes.concat (Frame.encodeFrame (Frame.jsonFrame (Lazy.toStrict (encode value))))))

invoke :: FilePath -> Value -> IO Value
invoke executable value = do
  (status,output,errors) <- call executable value
  unless (status == ExitSuccess) (fail errors)
  (Frame.Frame metadata body,remaining) <- right (runIdentity (Frame.readFrame (pure Nothing) (Bytes.pack output)))
  unless (Bytes.null body && Bytes.null remaining) (fail "Unexpected response bytes")
  right (eitherDecodeStrict' metadata)

right :: Show e => Either e a -> IO a
right = either (fail . show) pure
