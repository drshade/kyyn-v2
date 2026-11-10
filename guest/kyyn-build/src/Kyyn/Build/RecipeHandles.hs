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
data Handle = StateHandle Bool String String String | FlowHandle String String

handleImports :: [String] -> [Handle]
handleImports names = concatMap selected (nub names)
  where
    selected name = [StateHandle True endpoint reference name | endpoint <- ["Before","After","Target"],
      Just reference <- [stripPrefix ("Kyyn.Workspace." ++ endpoint ++ ".RecipeTypes.") name]] ++
      [FlowHandle reference name | endpoint <- ["After","Target"], Just reference <- [stripPrefix ("Kyyn.Workspace." ++ endpoint ++ ".RecipeFlows.") name]]

handleImportsWithStored :: [String] -> [String] -> [Handle]
handleImportsWithStored authored stored = nubBy (\a b -> name a == name b)
  (handleImports authored ++ map optional (handleImports stored))
  where
    optional (StateHandle _ endpoint reference selected) = StateHandle False endpoint reference selected
    optional handle = handle
    name (StateHandle _ _ _ selected) = selected
    name (FlowHandle _ selected) = selected

handleModules :: [Handle] -> Either String [String]
handleModules handles = nub . concat <$> traverse selected handles
  where
    selected (StateHandle _ _ reference _) = pure . Text.unpack . referenceModule <$> qualifiedReference True (Text.pack reference)
    selected (FlowHandle reference _) = Right [reference]

writeRecipeHandles :: FilePath -> FilePath -> [String] -> [FilePath] -> [FilePath]
  -> Reference -> [Handle] -> IO ([FilePath],[String],[String],[String])
writeRecipeHandles libdir generated packages beforeRoots afterRoots root handles = do
  let roots :: String -> [FilePath]
      roots endpoint = (if endpoint == "Before" then beforeRoots else afterRoots) ++ [generated]
      write name source = do
        let relative = map (\c -> if c == '.' then '/' else c) name ++ ".hs"
            path = generated </> relative
        occupied <- or <$> traverse (doesFileExist . (</> relative)) (nub (beforeRoots ++ afterRoots))
        when occupied (fail ("Authored source collides with generated module " ++ name))
        createDirectoryIfMissing True (takeDirectory path)
        writeFile path (unlines source)
  -- Emit all named bindings before loading any dependency closure.
  mapM_ (\handle -> case handle of
    StateHandle required _ reference name -> do
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
    StateHandle _ endpoint reference name -> do
      selected <- either fail pure (qualifiedReference True (Text.pack reference))
      (closure,exports) <- inspectExports libdir (roots endpoint) packages [name]
      let resolved = any (\entry -> any (\symbol -> symbol.exportName == "recipeType" && symbol.exportKind == ExportValue) entry.moduleExports) exports
      if not resolved then pure ([],[name],[],[]) else pure ([path | path <- closure, endpoint == "Before"],[name,Text.unpack (referenceModule selected)],
        ["describeEntry @" ++ reference ++ " " ++ show ("$import.state." ++ endpoint ++ "." ++ reference) ++
         " (SchemaMetadata [] [] []) " ++ show closure],
        ["TargetEvolution.RecipeBinding (OpenState " ++ show reference ++ ") " ++ name ++ ".recipeType"])
    FlowHandle reference name -> do
      (closure,exports) <- inspectExports libdir (roots "After") packages [reference]
      let candidates = nub [Text.unpack symbol.exportName | entry <- exports, symbol <- entry.moduleExports, symbol.exportKind == ExportValue]
          candidate value = "(" ++ show value ++ ",mkName " ++ show (reference ++ "." ++ value) ++ "," ++ show (reference ++ "." ++ value) ++ ")"
      write name (["{-# LANGUAGE TemplateHaskell, TypeApplications, OverloadedStrings #-}","module " ++ name ++ " where",
        "import Language.Haskell.TH (mkName)", "import Kyyn.Build.RecipeTypes (flowDefinitions)",
        "import qualified Kyyn.Recipe as Recipe", "import Kyyn.Evolution (RecipeDefinition)",
        "import qualified Kyyn.Runtime.Bindings as Bindings", "import qualified " ++ Text.unpack (referenceModule root),
        "import qualified " ++ reference,
        "$(flowDefinitions ''" ++ Text.unpack (referenceName root) ++ " [" ++ Text.unpack (Text.intercalate "," (map (Text.pack . candidate) candidates)) ++ "])"])
      (_,bindings) <- inspectExports libdir (roots "After") packages [name]
      let names = nub [Text.unpack symbol.exportName | entry <- bindings, symbol <- entry.moduleExports, symbol.exportKind == ExportValue]
      pure ([],[name],["recipeStateEntry " ++ show ("$import.flow." ++ reference ++ "." ++ value) ++ " " ++ show closure ++ " " ++ name ++ "." ++ value | value <- names],
        ["TargetEvolution.definitionBinding " ++ name ++ "." ++ value | value <- names])
  pure (nub (concat [closure | (closure,_,_,_) <- descriptions]),
    nub (concat [names | (_,names,_,_) <- descriptions]),concat [entries | (_,_,entries,_) <- descriptions],
    concat [bindings | (_,_,_,bindings) <- descriptions])
