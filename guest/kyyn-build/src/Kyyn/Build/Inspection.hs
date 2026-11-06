{-# LANGUAGE OverloadedStrings #-}
module Kyyn.Build.Inspection (inspectExports, packageOptions) where

import Control.Monad (forM, unless, filterM)
import Control.Monad.IO.Class (liftIO)
import Data.List (nub, sort)
import Data.Maybe (catMaybes)
import qualified Data.Text as Text
import GHC
import GHC.Iface.Type (ShowSub(..), ShowHowMuch(..), ShowForAllFlag(..))
import GHC.Types.Name (getOccString)
import GHC.Types.TyThing.Ppr (pprTyThing)
import GHC.Driver.Ppr (showSDoc)
import GHC.Driver.Env (hsc_units)
import GHC.Unit.State (listUnitInfo, unwireUnit)
import GHC.Unit.Info (unitIsExposed, unitId)
import GHC.Unit.Types (GenUnit(..), Definite(..), unitString)
import System.FilePath (normalise, (</>), (<.>))
import System.Directory (doesFileExist)
import Kyyn.Types.Guest (ExportDescription(..), ExportKind(..))

-- Explicit exposure preserves all libraries selected by the Nix compiler while
-- avoiding GHC's automatic hiding of sibling SDK components when runtime is
-- added to the final adapter compilation.
packageOptions :: FilePath -> IO [String]
packageOptions libdir = runGhc (Just libdir) $ do
  flags <- getSessionDynFlags
  _ <- setSessionDynFlags flags
  environment <- getSession
  pure ("-hide-all-packages" : concat
    [["-package-id",unitString (unwireUnit (hsc_units environment) (RealUnit (Definite (unitId unit))))] | unit <- listUnitInfo (hsc_units environment), unitIsExposed unit])

-- Compiler internals stay in the selected guest build environment. The caller
-- supplies that compiler's libdir and source roots, not an ambient package cache.
inspectExports :: FilePath -> [FilePath] -> [String] -> [String]
  -> IO ([FilePath],[ExportDescription])
inspectExports libdir roots options modules = runGhc (Just libdir) $
  handleSourceError (\problem -> printException problem >> liftIO (fail "GHC rejected selected source")) $ do
    initial <- getSessionDynFlags
    logger <- getLogger
    (configured,remaining,_) <- parseDynamicFlags logger initial
      (map noLoc (["-XGHC2021","-main-is","KyynGuestEntry.main"] ++ options))
    unless (null remaining) (liftIO (fail "Unsupported compiler options in guest build"))
    let flags = configured { importPaths = roots, backend = noBackend, ghcLink = NoLink }
    _ <- setSessionDynFlags flags
    localModules <- liftIO $ filterM (\name -> or <$> traverse doesFileExist
      [root </> map (\c -> if c == '.' then '/' else c) name <.> extension | root <- roots, extension <- ["hs","lhs"]]) (nub modules)
    targets <- traverse (\name -> guessTarget name Nothing Nothing) localModules
    setTargets targets
    loaded <- load LoadAllTargets
    case loaded of
      Failed -> liftIO (fail "GHC rejected selected source")
      Succeeded -> pure ()
    graph <- getModuleGraph
    let summaries = mgModSummaries graph
        sources = sort (nub (map normalise (catMaybes [ml_hs_file (ms_location summary) | summary <- summaries])))
    exports <- fmap concat $ forM (nub modules) $ \name -> do
      selected <- findModule (mkModuleName name) Nothing
      info <- getModuleInfo selected >>= maybe (liftIO (fail ("No module information: " ++ name))) pure
      let source = case [file | summary <- summaries, ms_mod summary == selected, Just file <- [ml_hs_file (ms_location summary)]] of
            file:_ -> normalise file
            [] -> ""
      forM (modInfoExports info) $ \exported -> do
        thing <- lookupName exported >>= maybe (liftIO (fail ("No export information: " ++ getOccString exported))) pure
        pure (ExportDescription (Text.pack name) (Text.pack (getOccString exported))
          (Text.pack (showSDoc flags (pprTyThing (ShowSub ShowIface ShowForAllWhen) thing))) (Text.pack source) (kind thing))
    pure (sources,exports)

kind :: TyThing -> ExportKind
kind (AnId _) = ExportValue
kind (AConLike _) = ExportConstructor
kind (ATyCon _) = ExportType
kind (ACoAxiom _) = ExportCoercion
