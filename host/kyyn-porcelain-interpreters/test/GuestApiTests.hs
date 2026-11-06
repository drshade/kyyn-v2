-- Read-only discovery uses the selected build's module descriptions, preserves
-- type/constructor names and compiler documentation, and propagates failures.
{-# LANGUAGE DataKinds, GADTs, OverloadedStrings #-}
module Main where

import Control.Monad (unless)
import Effectful (Eff, runPureEff)
import Effectful.Dispatch.Dynamic (interpret)
import Kyyn.Domain.Diagnostic (Diagnostic, errorDiagnostic)
import Kyyn.Domain.FileTree (FileTree, fileTree)
import Kyyn.Domain.GuestApi
import Kyyn.Plumbing.Capability.ApiInspection (ApiInspection(..))
import qualified Kyyn.Porcelain.Capability.GuestApi as Api
import Kyyn.Porcelain.Interpreter.GuestApi (runGuestApi)

main :: IO ()
main = do
  let symbols = [ExportDescription "Item" "data Item = Item Text" "Example.Item" Nothing ExportType,
        ExportDescription "Item" "Item :: Text -> Item" "Example.Item" Nothing ExportConstructor,
        ExportDescription "make" "make :: Text -> Item" "Original.make"
          (Just "Create an item: café.\n  Example indentation.") ExportValue]
      selected = ModuleDescription "Example" "src/Example.hs" Nothing ["instance Eq Item"] symbols
      catalogue = [selected]
      sources = either error id (fileTree [])
      readApi response = runPureEff . onlySelected sources response . runGuestApi sources ["Example"]
  assert "list modules" (readApi (Right catalogue) Api.listModules == Right ["Example"])
  assert "module projection" (readApi (Right catalogue) (Api.findModule "Example") == Right selected)
  assert "type/constructor namespaces" (readApi (Right catalogue) (Api.findSymbol "Example.Item") == Right ("Example",take 2 symbols))
  assert "unknown module" (refused (readApi (Right catalogue) (Api.findModule "Missing")))
  assert "unknown symbol" (refused (readApi (Right catalogue) (Api.findSymbol "make")))
  let failed = Left [errorDiagnostic "guest.build" "GHC rejected selected source"]
  assert "no fallback catalogue" (readApi failed Api.readCatalogue == failed)
  putStrLn "Selected guest API descriptions, names, documentation and failure propagation pass."

onlySelected :: FileTree -> Either [Diagnostic] [ApiModule] -> Eff (ApiInspection : es) a -> Eff es a
onlySelected expected response = interpret $ \_ (InspectApiModules sources modules) ->
  if sources == expected && modules == ["Example"] then pure response
  else error "API discovery changed the selected source or module"

refused :: Either a b -> Bool
refused (Left _) = True
refused _ = False

assert :: String -> Bool -> IO ()
assert label ok = unless ok (fail label)
