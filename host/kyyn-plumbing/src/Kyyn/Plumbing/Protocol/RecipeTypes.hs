module Kyyn.Plumbing.Protocol.RecipeTypes (recipeTypeBinding, recipeFlowBindings) where

import Data.List (nub)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import Kyyn.Domain.Contract (CheckedContract, rootType, contractId, contractFingerprint)
import Kyyn.Domain.DataType (haskellType, typeModules, reachableTypes)
import Kyyn.Domain.FileTree (FileTree, fileTree, files)
import Kyyn.Domain.Path (relativePath)
import Kyyn.Plumbing.Capability.SchemaInspection.Codecs (generateCodecs)

recipeTypeBinding :: String -> String -> CheckedContract -> Either String FileTree
recipeTypeBinding moduleName selected contract = do
  let codecModule = moduleName ++ ".Codec"
      state = rootType contract
  codec <- generateCodecs codecModule state
  let source = unlines $
        [ "{-# LANGUAGE OverloadedStrings #-}"
        , "module " ++ moduleName ++ " (recipeType) where"
        , "import Kyyn.Evolution (RecipeType)"
        , "import qualified Kyyn.Recipe.Internal as Internal"
        , "import Kyyn.Runtime.Json (encodeWith, decodeWith)"
        , "import qualified " ++ codecModule ++ " as State"
        ] ++ ["import qualified " ++ name | name <- nub (concatMap typeModules (reachableTypes state))] ++
        [ "-- | State binding for " ++ selected ++ "."
        , "recipeType :: RecipeType " ++ haskellType state
        , "recipeType = Internal.RecipeType " ++ show selected ++ " " ++
            show (contractFingerprint (contractId contract)) ++
            " (encodeWith State.rootCodec) (decodeWith State.rootCodec)"
        ]
  entries <- traverse (\(name, contents) -> do
    path <- relativePath (map (\c -> if c == '.' then '/' else c) name ++ ".hs")
    pure (path, Text.encodeUtf8 (Text.pack contents))) [(moduleName,source),(codecModule,codec)]
  fileTree entries

recipeFlowBindings :: String -> [(String,String,CheckedContract)] -> Either String FileTree
recipeFlowBindings moduleName declarations = do
  let entries = [(name,entry,contract,moduleName ++ ".State" ++ show index,"State" ++ show index) |
        (index,(name,entry,contract)) <- zip [0 :: Int ..] declarations]
  states <- traverse (\(_,_,contract,binding,_) -> recipeTypeBinding binding (haskellType (rootType contract)) contract) entries
  let source = unlines $ ["{-# LANGUAGE OverloadedStrings #-}",
        "module " ++ moduleName ++ " (" ++ comma [name | (name,_,_) <- declarations] ++ ") where",
        "import Kyyn.Evolution (RecipeDefinition)", "import qualified Kyyn.Recipe.Internal as Internal",
        "import Kyyn.Types.KnowledgeBase (Recipe(..), FlowEntryRef(..))"] ++
        ["import qualified " ++ binding ++ " as " ++ alias | (_,_,_,binding,alias) <- entries] ++
        ["import qualified " ++ name | name <- nub (concatMap (typeModules . rootType . (\(_,_,c) -> c)) declarations)] ++
        concat [[name ++ " :: RecipeDefinition " ++ haskellType (rootType contract),
          name ++ " = Internal.RecipeDefinition (ClosedAgent (FlowEntryRef " ++ show entry ++ ")) " ++ alias ++ ".recipeType"] |
          (name,entry,contract,_,alias) <- entries]
  path <- relativePath (map (\c -> if c == '.' then '/' else c) moduleName ++ ".hs")
  fileTree ((path,Text.encodeUtf8 (Text.pack source)) : concatMap files states)
  where
    comma [] = ""
    comma [name] = name
    comma (name:rest) = name ++ ", " ++ comma rest
