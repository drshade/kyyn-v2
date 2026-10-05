{-# LANGUAGE DataKinds, GADTs, LambdaCase, OverloadedStrings #-}
module Main where

import Control.Monad (unless)
import qualified Data.ByteString as Bytes
import Effectful (Eff, runPureEff)
import Effectful.Dispatch.Dynamic (interpret)
import Kyyn.Domain.GuestApi
import Kyyn.Domain.Path (DirectoryScope, directoryScope, relativeName)
import Kyyn.Plumbing.Capability.FileSystem (FileSystem(..))
import Kyyn.Plumbing.Interpreter.DhallHandling (runDhallHandling)
import Kyyn.Plumbing.Protocol.GuestApi (encodeCatalogue, decodeCatalogue)
import qualified Kyyn.Porcelain.Capability.GuestApi as Api
import Kyyn.Porcelain.Interpreter.GuestApi (runGuestApi)

main :: IO ()
main = do
  let symbols = [ApiSymbol "Item" TypeNamespace "Example.Item" "Type" Nothing Nothing,
        ApiSymbol "Item" ValueNamespace "Example.Item" "String -> Item" Nothing Nothing,
        ApiSymbol "make" ValueNamespace "Original.make" "String -> Item" (Just "make :: String -> Item")
          (Just "Create an item: café.\n  Example indentation.")]
      instances = ["instance Eq a => Eq (Item a)"]
      catalogue = [ApiModule "Example" symbols instances]
      scope = either error id (directoryScope "/test/runtime")
      bytes = either (error . show) id (runPureEff (runDhallHandling (encodeCatalogue catalogue)))
      readApi stored = runPureEff . runDhallHandling . onlyCatalogue scope stored . runGuestApi scope
  assert "real Dhall round trip" (runPureEff (runDhallHandling (decodeCatalogue bytes)) == Right catalogue)
  assert "list modules" (readApi (Just bytes) Api.listModules == Right ["Example"])
  assert "module projection" (readApi (Just bytes) (Api.findModule "Example") == Right (ApiModule "Example" symbols instances))
  assert "type/value namespaces" (readApi (Just bytes) (Api.findSymbol "Example.Item") == Right ("Example",take 2 symbols))
  assert "unknown module" (refused (readApi (Just bytes) (Api.findModule "Missing")))
  assert "unknown symbol" (refused (readApi (Just bytes) (Api.findSymbol "make")))
  assert "missing catalogue" (refused (readApi Nothing Api.readCatalogue))
  assert "malformed catalogue" (refused (readApi (Just "not dhall") Api.readCatalogue))
  assert "wrong catalogue shape" (refused (readApi (Just "{ version = +1, modules = [1] }") Api.readCatalogue))
  assert "unsupported version" (refused (readApi (Just "{ version = +3, modules = [] : List { name : Text, instances : List Text, symbols : List { name : Text, namespace : < Type | Value >, definedAs : Text, checkedSignature : Text, declaration : Optional Text, documentation : Optional Text } } }") Api.readCatalogue))
  putStrLn "Guest catalogue Dhall round trips, read-only discovery and refusal tests passed."

onlyCatalogue :: DirectoryScope -> Maybe Bytes.ByteString -> Eff (FileSystem : es) a -> Eff es a
onlyCatalogue expected contents = interpret $ \_ -> \case
  ReadOptionalBytes scope path | scope == expected && relativeName path == "guest-api.dhall" -> pure contents
  _ -> error "API discovery performed an unexpected filesystem operation"

refused :: Either a b -> Bool
refused (Left _) = True
refused _ = False

assert :: String -> Bool -> IO ()
assert label ok = unless ok (fail label)
