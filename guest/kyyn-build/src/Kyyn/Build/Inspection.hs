{-# LANGUAGE OverloadedStrings #-}
module Kyyn.Build.Inspection (inspectExports, sourceDependencies, BindingNeeds(..), requiredBindings, packageOptions, packageModuleNames) where

import Kyyn.Build.Language (guestLanguageFlags)

import Control.Monad (forM, unless, filterM)
import Control.Monad.IO.Class (liftIO)
import Data.List (nub, sort, isPrefixOf)
import Data.Maybe (catMaybes)
import qualified Data.Text as Text
import GHC
import GHC.Driver.Make (depanalPartial)
import GHC.Iface.Type (ShowSub(..), ShowHowMuch(..), ShowForAllFlag(..), AltPpr(..))
import GHC.Types.Name (getOccString, nameModule_maybe)
import GHC.Utils.Outputable (ppr, PromotionTickContext(..))
import GHC.Tc.Types (tcg_rdr_env)
import GHC.Types.Name.Ppr (mkNamePprCtx)
import GHC.Types.TyThing.Ppr (pprTyThing)
import GHC.Driver.Ppr (showSDocForUser)
import GHC.Driver.Env (hsc_units, hsc_unit_env)
import GHC.Unit.State (listUnitInfo, unwireUnit)
import GHC.Unit.Info (unitIsExposed, unitId, unitExposedModules)
import GHC.Unit.Types (GenUnit(..), Definite(..), unitString)
import System.FilePath (normalise, (</>), (<.>))
import System.Directory (doesFileExist)
import Kyyn.Types.Guest (ModuleDescription(ModuleDescription), ExportDescription(ExportDescription), ExportKind(..))

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

packageModuleNames :: FilePath -> IO [String]
packageModuleNames libdir = runGhc (Just libdir) $ do
  flags <- getSessionDynFlags
  _ <- setSessionDynFlags flags
  environment <- getSession
  pure (sort (nub [moduleNameString name | unit <- listUnitInfo (hsc_units environment), unitIsExposed unit,
    (name,_) <- unitExposedModules unit]))

-- Compiler internals stay in the selected guest build environment. The caller
-- supplies that compiler's libdir and source roots, not an ambient package cache.
inspectExports :: FilePath -> [FilePath] -> [String] -> [String]
  -> IO ([FilePath],[ModuleDescription])
inspectExports libdir roots options modules = runGhc (Just libdir) $
  handleSourceError (\problem -> printException problem >> liftIO (fail "GHC rejected selected source")) $ do
    flags <- configure roots options modules
    loaded <- load LoadAllTargets
    case loaded of
      Failed -> liftIO (fail "GHC rejected selected source")
      Succeeded -> pure ()
    graph <- getModuleGraph
    let summaries = mgModSummaries graph
        sources = sort (nub (map normalise (catMaybes [ml_hs_file (ms_location summary) | summary <- summaries])))
    exports <- forM (nub modules) $ \name -> do
      selected <- findModule (mkModuleName name) Nothing
      info <- getModuleInfo selected >>= maybe (liftIO (fail ("No module information: " ++ name))) pure
      let source = case [file | summary <- summaries, ms_mod summary == selected, Just file <- [ml_hs_file (ms_location summary)]] of
            file:_ -> normalise file
            [] -> ""
      setContext [IIDecl (simpleImportDecl (mkModuleName name))]
      exportedNames <- getNamePprCtx
      environment <- getSession
      names <- case [summary | summary <- summaries, ms_mod summary == selected] of
        summary:_ -> do
          checked <- typecheckModule =<< parseModule summary
          pure (mkNamePprCtx (PromTickCtx True False) (hsc_unit_env environment) (tcg_rdr_env (fst (tm_internals_ checked))))
        [] -> pure exportedNames
      let render = showSDocForUser flags (hsc_units environment) names
      symbols <- forM (modInfoExports info) $ \exported -> do
        thing <- lookupName exported >>= maybe (liftIO (fail ("No export information: " ++ getOccString exported))) pure
        docs <- getDocs exported
        let documentation = case docs of
              Right (Just chunks,_) -> Just (Text.intercalate "\n" (map renderDoc chunks))
              _ -> Nothing
            visibleChildren = [getOccName child | child <- modInfoExports info,
              nameModule_maybe child == nameModule_maybe exported]
            declaration = ShowSub (ShowSome (Just (`elem` visibleChildren)) (AltPpr Nothing)) ShowForAllWhen
            origin = maybe "" ((++ ".") . moduleNameString . moduleName) (nameModule_maybe exported) ++ getOccString exported
        pure (ExportDescription (Text.pack (getOccString exported))
          (Text.pack (render (pprTyThing declaration thing)))
          (Text.pack origin) documentation (kind thing))
      let documentation = renderDoc <$> (modInfoIface info >>= mi_docs >>= docs_mod_hdr)
          -- GHC's ModuleInfo instance accessor is deliberately undefined for
          -- package modules. Their instances are available on the interface.
          instances
            | not (null source) = [Text.pack (render (ppr entry)) | entry <- modInfoInstances info,
                nameModule_maybe (getName entry) == Just selected]
            | otherwise = maybe [] (map (Text.pack . render . ppr) . mi_insts) (modInfoIface info)
      pure (ModuleDescription (Text.pack name) (Text.pack source) documentation instances symbols)
    pure (sources,exports)

-- | Dependency paths only, for modules whose exports have already been checked
-- in this build phase. GHC resolves imports/CPP/boot files; this does not establish
-- type correctness and must not replace export inspection or final compilation.
sourceDependencies :: FilePath -> [FilePath] -> [String] -> [String] -> IO [FilePath]
sourceDependencies libdir roots options modules = runGhc (Just libdir) $ do
  _ <- configure roots options modules
  graph <- depanal [] False
  pure (sort (nub (map normalise (catMaybes
    [ml_hs_file (ms_location summary) | summary <- mgModSummaries graph]))))

-- Dependency analysis reads imports before generated modules exist. The partial
-- graph retains their consumers; the final load still reports every source error.
data BindingNeeds = BindingNeeds { rootBindings :: Bool, toolBindings :: Bool, workspaceBindings :: Bool }
  deriving (Eq, Show)
requiredBindings :: FilePath -> [FilePath] -> [String] -> [String] -> IO BindingNeeds
requiredBindings libdir roots options modules = runGhc (Just libdir) $ do
  _ <- configure roots options modules
  (_,graph) <- depanalPartial [] False
  let requested = modules ++ map (moduleNameString . unLoc . snd)
        (concatMap (\summary -> ms_srcimps summary ++ ms_textual_imps summary) (mgModSummaries graph))
      tools name = name `elem` ["Kyyn.Connectors","Kyyn.Agentic","KyynToolCalls"] || "Kyyn.Plugins." `isPrefixOf` name
      workspace name = "Kyyn.Workspace." `isPrefixOf` name || name == "KyynFrozenProposal"
  pure (BindingNeeds ("KyynQueryBindings" `elem` requested) (any tools requested) (any workspace requested))

configure :: [FilePath] -> [String] -> [String] -> Ghc DynFlags
configure roots options modules = do
  initial <- getSessionDynFlags
  logger <- getLogger
  (configured,remaining,_) <- parseDynamicFlags logger initial
    (map noLoc (guestLanguageFlags ++ ["-haddock","-main-is","KyynGuestEntry.main"] ++ options))
  unless (null remaining) (liftIO (fail "Unsupported compiler options in guest build"))
  let flags = configured { importPaths = roots, backend = noBackend, ghcLink = NoLink }
  _ <- setSessionDynFlags flags
  localModules <- liftIO $ filterM (\name -> or <$> traverse doesFileExist
    [root </> map (\c -> if c == '.' then '/' else c) name <.> extension | root <- roots, extension <- ["hs","lhs"]]) (nub modules)
  targets <- traverse (\name -> guessTarget name Nothing Nothing) localModules
  setTargets targets
  pure flags

renderDoc :: HsDoc GhcRn -> Text.Text
renderDoc = Text.pack . renderHsDocString . hsDocString

kind :: TyThing -> ExportKind
kind (AnId _) = ExportValue
kind (AConLike _) = ExportConstructor
kind (ATyCon _) = ExportType
kind (ACoAxiom _) = ExportCoercion
