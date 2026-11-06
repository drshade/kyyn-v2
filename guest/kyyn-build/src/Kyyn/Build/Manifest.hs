{-# LANGUAGE OverloadedStrings #-}
module Kyyn.Build.Manifest
  ( Manifest(..), Query(..), Tool(..), Output(..), Reference, referenceName
  , referenceModule, parseManifest, parsePluginManifest, qualifiedReference, ConfiguredInstance(..), parseInstances
  ) where

import Control.Monad (unless)
import Data.Bifunctor (first)
import Data.Char (isAlphaNum, isLower, isUpper)
import Data.Foldable (toList)
import Data.List (nub, sort)
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Void (Void)
import qualified Dhall.Core as D
import qualified Dhall.Map as Map
import qualified Dhall.Parser as Parser
import qualified Dhall.TypeCheck as TypeCheck

-- References are names, never Haskell expressions supplied to code generation.
newtype Reference = Reference Text deriving (Eq, Show)

referenceName :: Reference -> Text
referenceName (Reference name) = name

referenceModule :: Reference -> Text
referenceModule (Reference name) = Text.intercalate "." (init (Text.splitOn "." name))

data Manifest = Manifest
  { schemaType :: Reference, schemaMetadata :: Reference, validator :: Reference
  , queries :: [Query], tools :: [Tool], outputs :: [Output]
  } deriving (Eq, Show)

data Query = Query
  { queryName :: Text, queryDescription :: Text, queryImplementation :: Reference
  , inputType :: Reference, inputMetadata :: Reference
  , resultType :: Reference, resultMetadata :: Reference
  } deriving (Eq, Show)

data Tool = Tool Text Text Reference Reference Reference deriving (Eq, Show)
data Output = Output Text Text Text Text Text Text deriving (Eq, Show)

parseManifest :: Text -> Either String Manifest
parseManifest source = do
  parsed <- first show (Parser.exprFromText "kb.dhall" source)
  closed <- traverse (const (Left "kb.dhall must be self-contained; imports are not supported")) parsed
  _ <- first show (TypeCheck.typeOf closed)
  fields <- record (D.normalize closed)
  let required = ["schemaType","schemaMetadata","validator","queries","tools"]
  unless (sort (Map.keys fields) `elem` [sort required,sort ("outputs":required)])
    (Left "Unexpected or missing kb.dhall fields")
  checkList (textRecord ["name","description","implementation","inputType","inputMetadata","resultType","resultMetadata"])
    =<< field "queries" fields
  checkList (textRecord ["name","description","implementation","inputType","resultType"])
    =<< field "tools" fields
  case Map.lookup "outputs" fields of
    Nothing -> pure ()
    Just value -> checkList (D.Record (Map.fromList
      ([(name,D.makeRecordField D.Text) | name <- ["name","description","query"]] ++
       [("sink",D.makeRecordField (textRecord ["plugin","instanceName","method"]))]))) (D.recordFieldValue value)
  declarations <- field "queries" fields >>= list >>= traverse query
  toolDeclarations <- field "tools" fields >>= list >>= traverse tool
  outputDeclarations <- maybe (Right []) (\value -> list (D.recordFieldValue value) >>= traverse output) (Map.lookup "outputs" fields)
  unique "query" (map queryName declarations)
  unique "tool" [name | Tool name _ _ _ _ <- toolDeclarations]
  unique "output" [name | Output name _ _ _ _ _ <- outputDeclarations]
  Manifest <$> refField True "schemaType" fields <*> refField False "schemaMetadata" fields
    <*> refField False "validator" fields <*> pure declarations <*> pure toolDeclarations <*> pure outputDeclarations
  where
    query expression = do
      fields <- exact ["name","description","implementation","inputType","inputMetadata","resultType","resultMetadata"] expression
      Query <$> textField "name" fields <*> textField "description" fields
        <*> refField False "implementation" fields <*> refField True "inputType" fields
        <*> refField False "inputMetadata" fields <*> refField True "resultType" fields
        <*> refField False "resultMetadata" fields
    tool expression = do
      fields <- exact ["name","description","implementation","inputType","resultType"] expression
      Tool <$> textField "name" fields <*> textField "description" fields
        <*> refField False "implementation" fields <*> refField True "inputType" fields <*> refField True "resultType" fields
    output expression = do
      fields <- exact ["name","description","query","sink"] expression
      sink <- field "sink" fields >>= exact ["plugin","instanceName","method"]
      Output <$> textField "name" fields <*> textField "description" fields <*> textField "query" fields
        <*> textField "plugin" sink <*> textField "instanceName" sink <*> textField "method" sink

-- Installed plugin manifests are captured source, so imports would make the
-- selected build depend on paths outside that capture.
parsePluginManifest :: Text -> Either String (Text, Text)
parsePluginManifest source = do
  parsed <- first show (Parser.exprFromText "kyyn-plugin.dhall" source)
  closed <- traverse (const (Left "kyyn-plugin.dhall must be self-contained")) parsed
  _ <- first show (TypeCheck.typeOf closed)
  fields <- exact ["name","entryModule"] (D.normalize closed)
  name <- textField "name" fields
  entry <- textField "entryModule" fields
  unless (not (Text.null name) && Text.all (\c -> c `elem` ['a'..'z'] || c `elem` ['0'..'9'] || c == '-') name
    && not (Text.isPrefixOf "-" name || Text.isSuffixOf "-" name || Text.isInfixOf "--" name))
    (Left "Invalid plugin name")
  _ <- qualifiedReference False (entry <> ".connectors")
  pure (name,entry)

data ConfiguredInstance = ConfiguredInstance
  { instanceName :: Text, instanceBinding :: Text, instanceConnector :: Text } deriving (Eq, Show)

-- Only binding identities are needed to generate typed handles. The host checks
-- the configuration value against the described connector contract before use.
parseInstances :: Text -> Either String [ConfiguredInstance]
parseInstances source = do
  parsed <- first show (Parser.exprFromText "plugin configuration" source)
  closed <- traverse (const (Left "Plugin configuration must be self-contained")) parsed
  _ <- first show (TypeCheck.typeOf closed)
  values <- list (D.normalize closed)
  instances <- traverse instanceValue values
  unique "instance" (map instanceName instances)
  unique "binding" (map instanceBinding instances)
  pure instances
  where
    instanceValue value = do
      fields <- exact ["name","binding","connector"] value
      name <- textField "name" fields
      binding <- textField "binding" fields
      _ <- qualifiedReference False ("Generated." <> binding)
      connector <- field "connector" fields >>= \selected -> case selected of
        D.App (D.Field (D.Union _) selection) _ -> Right (D.fieldSelectionLabel selection)
        _ -> Left "Expected a selected connector union with a configuration value"
      pure (ConfiguredInstance name binding connector)

type Fields s = Map.Map Text (D.RecordField s Void)

record :: D.Expr s Void -> Either String (Fields s)
record (D.RecordLit fields) = Right fields
record _ = Left "Expected a manifest record"

exact :: [Text] -> D.Expr s Void -> Either String (Fields s)
exact names expression = do
  fields <- record expression
  unless (sort (Map.keys fields) == sort names) (Left "Unexpected or missing manifest declaration fields")
  pure fields

field :: Text -> Fields s -> Either String (D.Expr s Void)
field name fields = maybe (Left ("Missing manifest field: " ++ Text.unpack name))
  (Right . D.recordFieldValue) (Map.lookup name fields)

textField :: Text -> Fields s -> Either String Text
textField name fields = field name fields >>= \value -> case value of
  D.TextLit (D.Chunks [] text) -> Right text
  _ -> Left ("Expected Text in manifest field: " ++ Text.unpack name)

refField :: Bool -> Text -> Fields s -> Either String Reference
refField typeName name fields = do
  text <- textField name fields
  first (("Manifest field " ++ Text.unpack name ++ ": ") ++) (qualifiedReference typeName text)

qualifiedReference :: Bool -> Text -> Either String Reference
qualifiedReference typeName text = do
  let parts = Text.splitOn "." text
      identifier start part = case Text.uncons part of
        Just (firstChar,rest) -> start firstChar && Text.all (\c -> isAlphaNum c || c == '_' || c == '\'') rest
        Nothing -> False
  unless (length parts >= 2 && all (identifier isUpper) (init parts)
    && identifier (if typeName then isUpper else \c -> isLower c || c == '_') (last parts))
    (Left "Expected a qualified Haskell name")
  pure (Reference text)

list :: D.Expr s Void -> Either String [D.Expr s Void]
list (D.ListLit _ values) = Right (toList values)
list _ = Left "Expected a manifest list"

unique :: String -> [Text] -> Either String ()
unique label names = unless (all (not . Text.null) names && length names == length (nub names))
  (Left ("Manifest " ++ label ++ " names must be nonempty and unique"))

textRecord :: [Text] -> D.Expr s Void
textRecord names = D.Record (Map.fromList [(name,D.makeRecordField D.Text) | name <- names])

-- Empty lists still have a declared element type; do not silently accept [] of
-- an unrelated type just because there are no values to inspect.
checkList :: D.Expr s Void -> D.Expr s Void -> Either String ()
checkList element expression = do
  actual <- first (const "Invalid manifest list type") (TypeCheck.typeOf expression)
  unless (D.judgmentallyEqual actual (D.App D.List element)) (Left "Incorrect manifest list element type")
