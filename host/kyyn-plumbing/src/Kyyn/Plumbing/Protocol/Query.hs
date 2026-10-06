module Kyyn.Plumbing.Protocol.Query (queryBindings, querySources, decodeQueryReply) where

import Control.Monad (unless)
import Data.Aeson (Value, eitherDecodeStrict, withObject, withArray, (.:))
import Data.Aeson.Types (parseEither)
import qualified Data.Aeson.KeyMap as Keys
import qualified Data.ByteString as Bytes
import Data.Foldable (toList)
import Data.List (nub, intercalate, sort)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import Kyyn.Domain.Contract (RootContract, rootSchema, rootType, collectionContracts, CollectionContract(..))
import Kyyn.Domain.DataType (DataType(..), Constructor(..), haskellType, typeModules)
import Kyyn.Domain.Path (RelativePath, relativePath)
import Kyyn.Types.Fact (FactId(..))
import Kyyn.Types.Query (ReadAccess(..))
import Kyyn.Plumbing.Capability.GuestCompilation.Types (GuestSources, guestSources, bindingModule)
import Kyyn.Plumbing.Capability.SchemaInspection.Codecs (generateCodecs)

queryBindings :: RootContract -> Either String (RelativePath, Bytes.ByteString)
queryBindings selected = do
  path <- relativePath "KyynQueryBindings.hs"
  let contract = rootSchema selected
      root = rootType contract
  (constructor, fields) <- case root of
    Algebraic _ _ [Constructor name fields] -> Right (name, fields)
    _ -> Left "Query bindings require a root record"
  bindings <- traverse (binding root constructor fields) (collectionContracts contract)
  pure (path, utf8 (unlines
    (["module KyynQueryBindings (Query" ++ concatMap ((", " ++) . bindingName) (collectionContracts contract) ++ ") where",
      "import qualified Kyyn.Types.Query as SDK"] ++ imports [root] ++
      ["type Query a = SDK.Query " ++ haskellType root ++ " a"] ++ concat bindings)))
  where
    bindingName (CollectionContract _ field _ _) = field
    binding root constructor fields (CollectionContract name field payload _) = do
      unless (Just field `elem` map fst fields) (Left ("Missing collection field " ++ field))
      let patternFields = [if label == Just field then "values" else "_" | (label,_) <- fields]
      pure [field ++ " :: SDK.CollectionBinding " ++ haskellType root ++ " " ++ haskellType payload,
        field ++ " = SDK.CollectionBinding " ++ show name ++ " (\\(" ++ constructor ++ " " ++
          unwords patternFields ++ ") -> values)"]

querySources :: RootContract -> DataType -> DataType -> String
  -> [(RelativePath, Bytes.ByteString)] -> Either String GuestSources
querySources selected input result implementation sources = do
  moduleName <- bindingModule implementation
  bindings <- queryBindings selected
  let root = rootType (rootSchema selected)
  codecs <- traverse (\(name,t) -> do
    path <- relativePath (name ++ ".hs")
    source <- generateCodecs name t
    pure (path, utf8 source))
    [("KyynQueryRootCodec",root), ("KyynQueryInputCodec",input), ("KyynQueryResultCodec",result)]
  entryPath <- relativePath "KyynQueryEntry.hs"
  let entry = unlines $
        ["module KyynQueryEntry where", "import qualified " ++ moduleName] ++ imports [root,input,result] ++
        ["import qualified KyynQueryRootCodec as RootCodec",
         "import qualified KyynQueryInputCodec as InputCodec",
         "import qualified KyynQueryResultCodec as ResultCodec",
         "import qualified Kyyn.Types.Query as SDK", "import Kyyn.Runtime.Query",
         "selected :: " ++ haskellType input ++ " -> SDK.Query " ++ haskellType root ++ " " ++ haskellType result,
         "selected = " ++ implementation,
         "main :: IO ()", "main = do", "  input <- getContents",
         "  output <- either fail pure (executeQuery RootCodec.rootCodec InputCodec.rootCodec ResultCodec.rootCodec selected input)",
         "  putStrLn output"]
  guestSources entryPath (sources ++ [bindings, (entryPath, utf8 entry)] ++ codecs)

imports :: [DataType] -> [String]
imports types = ["import qualified " ++ name | name <- nub
  (concatMap typeModules types)]

utf8 :: String -> Bytes.ByteString
utf8 = Text.encodeUtf8 . Text.pack

decodeQueryReply :: Bytes.ByteString -> Either String (Value, [ReadAccess])
decodeQueryReply bytes = eitherDecodeStrict bytes >>= parseEither
  (withObject "QueryReply" $ \o -> do
    unless (sort (Keys.keys o) == ["result", "trace"]) (fail "Expected result and trace")
    value <- o .: "result"
    trace <- o .: "trace" >>= withArray "ReadTrace" (traverse access . toList)
    pure (value, trace))
  where
    access = withObject "ReadAccess" $ \o -> do
      kind <- o .: "tag"
      case kind :: String of
        "Collection" | sort (Keys.keys o) == ["collection", "tag"] -> CollectionRead <$> o .: "collection"
        "Fact" | sort (Keys.keys o) == ["collection", "factId", "tag"] ->
          FactRead <$> o .: "collection" <*> (FactId <$> o .: "factId")
        _ -> fail ("Invalid read access: " ++ intercalate ", " (map show (Keys.keys o)))
