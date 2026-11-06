-- A real subprocess describes and invokes the same compiled fixture through the
-- host frame codec. Nix derivation/source capture is tested separately.
{-# LANGUAGE DeriveAnyClass, DerivingStrategies, DeriveGeneric, OverloadedStrings, TypeApplications, OverloadedRecordDot #-}
module Main (main) where

import Control.Monad (unless, forM_)
import Control.Exception (SomeException, try)
import Data.Aeson (Value(..), object, (.=), encode, eitherDecodeStrict', toJSON)
import qualified Data.Aeson.KeyMap as Keys
import qualified Data.ByteString.Char8 as Bytes
import qualified Data.ByteString.Lazy as Lazy
import Data.Either (isLeft)
import qualified Kyyn.Domain.Guest as Host
import Data.Fixed (Fixed, E2)
import Data.Functor.Identity (runIdentity)
import GHC.Generics (Generic)
import System.Environment (getArgs, getExecutablePath)
import System.Exit (ExitCode(..))
import qualified System.Process.Typed as Process
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
guest = runGuest [G.ModuleDescription "Fixture" "GuestProtocolTests.hs" Nothing []
  [G.ExportDescription "Root" "data Root" "Fixture.Root" (Just "Fixture documentation: café") G.ExportType]]
  [validationEntry @Root annotations ["GuestProtocolTests.hs"] (const (ValidationReport [])),
   queryEntry @Root "total" (annotations,["GuestProtocolTests.hs"])
     (SchemaMetadata [] [] [],[]) (SchemaMetadata [] [] [],[]) total]

main :: IO ()
main = do
  args <- getArgs
  case args of
    ["--guest"] -> guest
    ["--built",path] -> check (path,[])
    ["--schema-built",path] -> checkSchema (path,[])
    ["--api-built",path] -> checkApi False (path,[])
    ["--api-bindings-built",path] -> checkApi True (path,[])
    [] -> getExecutablePath >>= \path -> check (path,["--guest"])
    _ -> fail "Expected --guest or --built EXECUTABLE"

checkApi :: Bool -> (FilePath,[String]) -> IO ()
checkApi withBindings executable = do
  value <- invoke executable (object ["operation" .= ("describe" :: String)])
  description <- right (eitherDecodeStrict' (Lazy.toStrict (encode value)) :: Either String G.GuestDescription)
  _ <- right (Host.checkGuest description)
  unless (null description.entries) (fail "API discovery produced runnable entries")
  let symbols = [(m.moduleName,e.exportName) | m <- description.modules, e <- m.moduleExports]
  let expected = if withBindings then [("Queries","total"),("KyynQueryBindings","items")]
        else [("Example","answer"),("Data.Maybe","fromMaybe"),("Kyyn.Optics","field")]
  unless (all (`elem` symbols) expected)
    (fail "Authored or installed-library exports missing")
  unless (all ((/= "private") . snd) symbols) (fail "Private implementation exported")
  putStrLn "API discovery inspects selected authored and locked library modules."

checkSchema :: (FilePath,[String]) -> IO ()
checkSchema executable = do
  value <- invoke executable (object ["operation" .= ("describe" :: String)])
  description <- right (eitherDecodeStrict' (Lazy.toStrict (encode value)) :: Either String G.GuestDescription)
  _ <- right (Host.checkGuest description)
  case description.entries of
    [G.ContractEntry "root" selected] ->
      unless (selected.loadedSources == ["src/Main.hs"]) (fail "Wrong schema-only source closure")
    _ -> fail "Schema discovery produced runnable entries"
  unless (all ((/= "Queries") . G.moduleName) description.modules) (fail "Unfinished query included in schema discovery")
  (status,_,_) <- call executable (object ["operation" .= ("invoke" :: String),"entry" .= ("root" :: String),"argument" .= object []])
  unless (status /= ExitSuccess) (fail "Description-only entry was invokable")
  putStrLn "Schema discovery succeeds independently of unfinished query code."

check :: (FilePath,[String]) -> IO ()
check executable = do
  unsupported <- try (checkEntries
    [queryEntry @Root @() @Double "unsupported" (annotations,[])
      (SchemaMetadata [] [] [],[]) (SchemaMetadata [] [] [],[]) (const (pure 1.25))]) :: IO (Either SomeException ())
  unless (isLeft unsupported) (fail "Build preflight accepted an unsupported query result contract")
  descriptionValue <- invoke executable (object ["operation" .= ("describe" :: String)])
  description <- right (eitherDecodeStrict' (Lazy.toStrict (encode descriptionValue)) :: Either String G.GuestDescription)
  unless (description.protocol == G.protocolIdentity) (fail "Wrong protocol identity")
  _ <- right (Host.checkGuest description)
  unless (isLeft (Host.checkGuest description { G.protocol = "unexpected" })) (fail "Unknown guest protocol accepted")
  unless (isLeft (Host.checkGuest description { G.entries = description.entries ++ description.entries })) (fail "Duplicate entries accepted")
  let changeContracts change = description { G.entries = map (fmap change) description.entries }
  unless (isLeft (Host.checkGuest (changeContracts (\selected -> selected { G.identity = "incorrect" }))))
    (fail "Incorrect contract fingerprint accepted")
  unless (isLeft (Host.checkGuest (changeContracts (\selected -> selected { G.loadedSources = ["../outside.hs"] }))))
    (fail "Source traversal accepted")
  unless (map G.entryName description.entries == ["validate","total"]) (fail "Wrong registered entries")
  selectedRoot <- case [root | G.ValidatorEntry _ root <- description.entries] of
    [root] -> pure root
    _ -> fail "Missing validator contract"
  let malformed entry = object ["protocol" .= G.protocolIdentity,"entries" .= [entry],"modules" .= ([] :: [Value])]
      rejects value = unless (isLeft (eitherDecodeStrict' (Lazy.toStrict (encode value)) :: Either String G.GuestDescription))
        (fail "Malformed guest description passed the strict reader")
  forM_ [
    object ["entryName" .= ("validate" :: String),"kind" .= ("unknown" :: String),"root" .= selectedRoot],
    object ["entryName" .= ("validate" :: String),"kind" .= ("validator" :: String),"root" .= selectedRoot,
      "capabilities" .= ([] :: [String])],
    object ["entryName" .= ("total" :: String),"kind" .= ("query" :: String),"root" .= selectedRoot,
      "arguments" .= selectedRoot]] (rejects . malformed)
  case toJSON description of
    Object fields -> rejects (Object (Keys.insert "unexpected" Null fields))
    _ -> fail "Description encoder returned a non-object"
  let badExport = G.ExportDescription "Root" "data Root" "Main.Root" Nothing G.ExportType
  case toJSON badExport of
    Object fields -> unless (isLeft (eitherDecodeStrict' (Lazy.toStrict (encode
      (Object (Keys.insert "kind" (String "unknown") fields)))) :: Either String G.ExportDescription))
        (fail "Unknown export kind accepted")
    _ -> fail "Export encoder returned a non-object"
  forM_ description.entries $ \entry -> forM_ entry $ \selected ->
    do
      unless (selected.identity == D.fingerprint (D.contractIdentity selected.structure selected.metadata))
        (fail "Guest description fingerprint disagrees")
      unless ("src/Annotations.hs" `notElem` selected.loadedSources)
        (fail "Metadata-only source included in schema dependency closure")
  forM_ [selected | G.QueryEntry _ (G.QueryContracts _ arguments result) <- description.entries,
       selected <- [arguments,result]] $ \selected ->
    unless (selected.metadata == SchemaMetadata [] [] []) (fail "Root metadata leaked into query arguments or result")
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

call :: (FilePath,[String]) -> Value -> IO (ExitCode,Lazy.ByteString,Lazy.ByteString)
call (executable,arguments) value = Process.readProcess (Process.setStdin (Process.byteStringInput
  (Lazy.fromStrict (Bytes.concat (Frame.encodeFrame (Frame.jsonFrame (Lazy.toStrict (encode value)))))))
  (Process.proc executable arguments))

invoke :: (FilePath,[String]) -> Value -> IO Value
invoke executable value = do
  (status,output,errors) <- call executable value
  unless (status == ExitSuccess) (fail (show errors))
  (Frame.Frame metadata body,remaining) <- right (runIdentity (Frame.readFrame (pure Nothing) (Lazy.toStrict output)))
  unless (Bytes.null body && Bytes.null remaining) (fail "Unexpected response bytes")
  right (eitherDecodeStrict' metadata)

right :: Show e => Either e a -> IO a
right = either (fail . show) pure
