{-# LANGUAGE OverloadedStrings, OverloadedRecordDot #-}
module Kyyn.Build.RecipeHandles (handleImports, handleImportsWithStored, handleModules, writeRecipeHandles) where

import Control.Monad (forM, when)
import Data.List (nub, nubBy, stripPrefix)
import qualified Data.Text as Text
import System.Directory (createDirectoryIfMissing, doesFileExist)
import System.FilePath ((</>), takeDirectory)
import Kyyn.Build.Manifest (Reference, referenceName, referenceModule, qualifiedReference)
import Kyyn.Build.Inspection (inspectExports)
import Kyyn.Types.Guest

-- Only imports request handles. In particular, unfinished migration bodies need
-- not parse or typecheck to discover their workspace API.
data Handle = StateHandle Bool String String | FlowHandle String String

handleImports :: [String] -> [Handle]
handleImports names = concatMap selected (nub names)
  where
    selected name = [StateHandle True reference name | Just reference <- [stripPrefix "Kyyn.Workspace.Target.RecipeTypes." name]] ++
      [FlowHandle reference name | Just reference <- [stripPrefix "Kyyn.Workspace.Target.RecipeFlows." name]]

handleImportsWithStored :: [String] -> [String] -> [Handle]
handleImportsWithStored authored stored = nubBy (\a b -> name a == name b)
  (handleImports authored ++ map optional (handleImports stored))
  where
    optional (StateHandle _ reference selected) = StateHandle False reference selected
    optional handle = handle
    name (StateHandle _ _ selected) = selected
    name (FlowHandle _ selected) = selected

handleModules :: [Handle] -> Either String [String]
handleModules handles = nub . concat <$> traverse selected handles
  where
    selected (StateHandle _ reference _) = pure . Text.unpack . referenceModule <$> qualifiedReference True (Text.pack reference)
    selected (FlowHandle reference _) = Right [reference]

writeRecipeHandles :: FilePath -> FilePath -> [String] -> [FilePath]
  -> Reference -> [Handle] -> IO ([String],[String],[String])
writeRecipeHandles libdir generated packages sourceRoots root handles = do
  let roots = sourceRoots ++ [generated]
      write name source = do
        let relative = map (\c -> if c == '.' then '/' else c) name ++ ".hs"
            path = generated </> relative
        occupied <- or <$> traverse (doesFileExist . (</> relative)) sourceRoots
        when occupied (fail ("Authored source collides with generated module " ++ name))
        createDirectoryIfMissing True (takeDirectory path)
        writeFile path (unlines source)
  -- Emit all named bindings before loading any dependency closure.
  mapM_ (\handle -> case handle of
    StateHandle required reference name -> do
      selected <- either fail pure (qualifiedReference True (Text.pack reference))
      write name (["{-# LANGUAGE TemplateHaskell, TypeApplications, OverloadedStrings #-}","module " ++ name ++ " where",
        "import Language.Haskell.TH (mkName)","import Kyyn.Build.RecipeTypes (optionalStateDefinition)",
        "import Kyyn.Evolution (RecipeType)","import qualified Kyyn.Runtime.Bindings as Bindings",
        "import qualified " ++ Text.unpack (referenceModule selected)] ++
        if required then ["recipeType :: RecipeType " ++ reference,
          "recipeType = either (error . show) id (Bindings.recipeType @" ++ reference ++ " " ++ show reference ++ ")"]
        else ["$(optionalStateDefinition (mkName \"recipeType\") ''" ++ reference ++ " " ++ show reference ++ ")"])
    FlowHandle _ _ -> pure ()) handles
  descriptions <- forM handles $ \handle -> case handle of
    StateHandle _ reference name -> do
      selected <- either fail pure (qualifiedReference True (Text.pack reference))
      (closure,exports) <- inspectExports libdir roots packages [name]
      let resolved = any (\entry -> any (\symbol -> symbol.exportName == "recipeType" && symbol.exportKind == ExportValue) entry.moduleExports) exports
      if not resolved then pure ([name],[],[]) else pure ([name,Text.unpack (referenceModule selected)],
        ["describeEntry @" ++ reference ++ " " ++ show ("$import.state.Target." ++ reference) ++
         " (SchemaMetadata [] [] []) " ++ show closure],
        ["TargetEvolution.RecipeBinding (OpenState " ++ show reference ++ ") " ++ name ++ ".recipeType"])
    FlowHandle reference name -> do
      (closure,exports) <- inspectExports libdir roots packages [reference]
      let candidates = nub [Text.unpack symbol.exportName | entry <- exports, symbol <- entry.moduleExports, symbol.exportKind == ExportValue]
          candidate value = "(" ++ show value ++ ",mkName " ++ show (reference ++ "." ++ value) ++ "," ++ show (reference ++ "." ++ value) ++ ")"
      write name (["{-# LANGUAGE TemplateHaskell, TypeApplications, OverloadedStrings #-}","module " ++ name ++ " where",
        "import Language.Haskell.TH (mkName)", "import Kyyn.Build.RecipeTypes (flowDefinitions)",
        "import qualified Kyyn.Recipe as Recipe", "import Kyyn.Evolution (RecipeDefinition)",
        "import qualified Kyyn.Runtime.Bindings as Bindings", "import qualified " ++ Text.unpack (referenceModule root),
        "import qualified " ++ reference,
        "$(flowDefinitions ''" ++ Text.unpack (referenceName root) ++ " [" ++ Text.unpack (Text.intercalate "," (map (Text.pack . candidate) candidates)) ++ "])"])
      (_,bindings) <- inspectExports libdir roots packages [name]
      let names = nub [Text.unpack symbol.exportName | entry <- bindings, symbol <- entry.moduleExports, symbol.exportKind == ExportValue]
      pure ([name],["recipeStateEntry " ++ show ("$import.flow." ++ reference ++ "." ++ value) ++ " " ++ show closure ++ " " ++ name ++ "." ++ value | value <- names],
        ["TargetEvolution.definitionBinding " ++ name ++ "." ++ value | value <- names])
  pure (nub (concat [names | (names,_,_) <- descriptions]),concat [entries | (_,entries,_) <- descriptions],
    concat [bindings | (_,_,bindings) <- descriptions])
