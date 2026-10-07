module Kyyn.Plumbing.Protocol.RecipeTypes (recipeTypeBinding) where

import Data.List (nub)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import Kyyn.Domain.Contract (CheckedContract, rootType, contractId, contractFingerprint)
import Kyyn.Domain.DataType (haskellType, typeModules, reachableTypes)
import Kyyn.Domain.FileTree (FileTree, fileTree)
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
