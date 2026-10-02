module Kyyn.Plumbing.Capability.SchemaInspection.Agentic (generateAgenticCodec, generateAgenticInstance) where

import Data.List (intercalate, nub)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import Kyyn.Domain.DataType
import Kyyn.Domain.FileTree (FileTree, fileTree, files)
import Kyyn.Domain.Path (relativePath)
import Kyyn.Plumbing.Capability.GuestCompilation.Types (bindingModule)
import Kyyn.Plumbing.Capability.SchemaInspection.Codecs (generateCodecs)

-- | Generate one instance for a nominal, monomorphic type at its defining name.
generateAgenticInstance :: Int -> String -> DataType -> Either String FileTree
generateAgenticInstance index selected datatype = case datatype of
  Algebraic actual [] constructors | actual == selected -> do
    let private = "KyynModelContract" ++ show index
        public = "Kyyn.Contracts." ++ selected
    codec <- generateAgenticCodec private datatype
    path <- relativePath (map (\c -> if c == '.' then '/' else c) public ++ ".hs")
    let enum = not (null constructors) && all (\(Constructor _ fields) -> null fields) constructors
        source = unlines $
          ["module " ++ public ++ " (codec) where",
           "import Agentic.Contract (Contract(..), Codec)",
           "import qualified " ++ definingModule actual,
           "import qualified " ++ private ++ " as Generated"] ++
          ["import Agentic.Contract (Options(..), Option(..), OptionSet(..))" | enum] ++
          ["import qualified Data.Text as Text" | enum] ++
          [
           "-- | Generated model contract for " ++ actual ++ ".",
           "codec :: Codec " ++ actual, "codec = Generated.rootCodec",
           "instance Contract " ++ actual ++ " where", "  contract = codec"] ++
          (if enum then ["instance Options " ++ actual ++ " where",
            "  options = OptionSet Nothing " ++ list
              ["(Option " ++ constructor ++ " (Text.pack " ++ show (reverse (takeWhile (/= '.') (reverse constructor))) ++ ") Nothing)"
              | Constructor constructor [] <- constructors]] else [])
    fileTree (files codec ++ [(path,Text.encodeUtf8 (Text.pack source))])
  Algebraic actual [] _ -> Left ("Import Kyyn.Contracts." ++ actual ++ " at the type's defining name, not alias " ++ selected)
  _ -> Left (selected ++ ": generated Contract instances require a monomorphic data/newtype declaration; wrap other types in a named data/newtype")

-- | Derive a model contract and its wire codec from one checked Haskell type.
generateAgenticCodec :: String -> DataType -> Either String FileTree
generateAgenticCodec name datatype = do
  _ <- bindingModule (name ++ ".rootCodec")
  wire <- generateCodecs (name ++ "Wire") datatype
  shape <- shapeOf datatype >>= renderSchema
  let source = unlines $
        ["module " ++ name ++ " (rootCodec) where", "import qualified Agentic.Contract as A",
         "import qualified Agentic.Schema as S", "import qualified Data.Text as Text",
         "import Kyyn.Runtime.AgenticContract (fromWireCodec)", "import qualified " ++ name ++ "Wire as Wire"] ++
        ["import qualified " ++ m | m <- nub [definingModule n | Algebraic n _ _ <- reachableTypes datatype]] ++
        ["rootCodec :: A.Codec " ++ haskellType datatype,
         "rootCodec = fromWireCodec " ++ shape ++ " Wire.rootCodec"]
  entries <- traverse (\(moduleName,body) -> do
    path <- relativePath (map (\c -> if c == '.' then '/' else c) moduleName ++ ".hs")
    pure (path,Text.encodeUtf8 (Text.pack body))) [(name,source),(name ++ "Wire",wire)]
  fileTree entries

renderSchema :: Shape -> Either String String
renderSchema (Scalar TextScalar) = pure "(S.schemaOf (S.SString Nothing))"
renderSchema (Scalar IntegerScalar) = pure
  "(S.Schema Nothing Nothing [Text.pack \"Canonical decimal integer string, with no leading zeros or plus sign\"] (S.SString Nothing))"
renderSchema (Scalar BoolScalar) = pure "(S.schemaOf S.SBool)"
renderSchema (List inner) = (\schema -> "(S.schemaOf (S.SArray " ++ schema ++ "))") <$> renderSchema inner
renderSchema (Record fields) = (\members -> "(S.schemaOf (S.SObject " ++ list members ++ "))") <$> traverse field fields
renderSchema (Optional inner) = renderSchema (Union [("None",Nothing),("Some",Just inner)])
renderSchema (Union []) = Left "An empty union has no model-producible value"
renderSchema (Union variants) = (\members -> "(S.schemaOf (S.SSum " ++ list members ++ "))") <$> traverse variant variants
  where
    variant (name,payload) = do
      fields <- traverse (field . ("value",)) (maybe [] pure payload)
      pure ("S.Variant (Text.pack " ++ show name ++ ") Nothing " ++ list fields)
renderSchema (Reference name) = Left ("Unresolved model contract reference: " ++ name)

field :: (String,Shape) -> Either String String
field (name,shape) = (\schema -> "S.Field (Text.pack " ++ show name ++ ") " ++ schema ++ " True") <$> renderSchema shape

list :: [String] -> String
list values = "[" ++ intercalate ", " values ++ "]"
