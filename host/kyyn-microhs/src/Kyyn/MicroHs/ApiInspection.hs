{-# LANGUAGE ScopedTypeVariables #-}
module Kyyn.MicroHs.ApiInspection (inspectApi, ApiError(..)) where

import Control.DeepSeq (force)
import Control.Exception (SomeException, SomeAsyncException, ErrorCall, catch, evaluate, displayException, fromException, throwIO)
import Control.Monad (foldM)
import Data.Char (isAlpha, isSpace)
import Data.List (nub, nubBy, sortOn, isPrefixOf, stripPrefix, intercalate)
import Kyyn.Domain.GuestApi
import MicroHs.Compile (compileModuleP, addPreludeImport, emptyCache)
import MicroHs.CompileCache (cachedModules)
import MicroHs.Expr
import MicroHs.Flags
import MicroHs.Ident
import MicroHs.StateIO (runStateIO)
import MicroHs.TypeCheck (TModule(..), ValueExport(..), TypeExport(..))
import MicroHs.SymTab (Entry(..))
import MicroHs.Parse (parse, pTop)
import MicroHs.Fixity (resolveFixity, defaultFixity)
import MicroHs.TCMonad (fixTable)
import qualified MicroHs.IdentMap as IdentMap

data ApiError = ApiCompilerError String | ApiSourceError String | ApiNativeError String
  deriving (Eq, Show)

inspectApi :: FilePath -> [FilePath] -> [String] -> IO (Either ApiError [ApiModule])
inspectApi compiler sources selected = inspect `catch` failure
  where
    failure (err :: SomeException)
      | Just (_ :: SomeAsyncException) <- fromException err = throwIO err
      | Just (_ :: ErrorCall) <- fromException err = pure (Left (ApiCompilerError (displayException err)))
      | otherwise = pure (Left (ApiNativeError (displayException err)))
    flags = defaultFlags { mhsdir = compiler, srcPaths = sources ++ [compiler ++ "/lib"],
      cppArgs = ["-DMIN_VERSION_base(x,y,z)=1"] }
    inspect = do
      (modules,cache) <- foldM compile ([],emptyCache) (nub selected)
      declarations <- mapM readDeclarations
        [(unIdent (tModuleName m), slocFile (slocIdent (tModuleName m)))
        | m <- cachedModules cache, "Kyyn." `isPrefixOf` unIdent (tModuleName m)]
      result <- evaluate (force (sequence declarations >>= \table -> mapM (project table) modules))
      pure (either (Left . ApiSourceError) Right result)
    compile (modules,cache) selectedModule = do
      let imported = mkIdent selectedModule
          witness = addPreludeImport (EModule (mkIdent "KyynApiWitness") [ExpModule imported]
            [Import (ImportSpec ImpNormal False imported Nothing Nothing)])
      (((checked,_,_,_,_),tc),next) <- runStateIO (compileModuleP flags ImpNormal witness) cache
      _ <- evaluate (force checked)
      pure (modules ++ [(selectedModule, checked, IdentMap.toList (fixTable tc))],next)

readDeclarations :: (String, FilePath) -> IO (Either String (String, ([EDef],[String])))
readDeclarations (name,path) = do
  source <- readFile path
  pure $ case parse pTop path source of
    Left message -> Left message
    Right (EModule _ _ declarations) -> Right (name,(declarations,lines source))

project :: [(String,([EDef],[String]))] -> (String,TModule a,[(Ident,Fixity)]) -> Either String ApiModule
project declarations (selected,checked,fixities) = do
  types <- mapM typeSymbol (tTypeExps checked)
  values <- mapM valueSymbol (tValueExps checked ++ concat
    [associated | TypeExport _ _ associated <- tTypeExps checked])
  pure (ApiModule selected (sortOn key (nubBy (\a b -> key a == key b) (types ++ values))))
  where
    key (ApiSymbol n ns origin _ _ _) = (n,ns,origin)
    typeSymbol (TypeExport n entry _) = symbol TypeNamespace n entry
    valueSymbol (ValueExport n entry) = symbol ValueNamespace n entry
    symbol ns visible (Entry expression checkedType) = do
      origin <- case expression of
        EVar ident -> Right ident
        ECon constructor -> Right (conIdent constructor)
        _ -> Left ("Unsupported exported entry: " ++ unIdent visible)
      let defining = unIdent (qualOf origin)
          (defs,sourceLines) = maybe ([],[]) id (lookup defining declarations)
          declarationNames = concatMap (\definition -> case (ns,definition) of
            (ValueNamespace,Sign identifiers _) -> identifiers
            (TypeNamespace,Type (n,_) _) -> [n]
            (TypeNamespace,Data (n,_) _ _) -> [n]
            (TypeNamespace,Newtype (n,_) _ _) -> [n]
            _ -> []) defs
          docs = case [n | n <- declarationNames, n == unQualIdent origin] of
            [n] -> documentationBefore (slocIdent n) sourceLines
            _ -> Nothing
          matches = case ns of
            ValueNamespace -> [Sign [visible] t | Sign names t <- defs, unQualIdent origin `elem` names]
            TypeNamespace -> [Type (visible,args) t | Type (n,args) t <- defs, n == unQualIdent origin]
      declared <- case matches of
        [] -> Right Nothing
        [Sign _ t] -> do
          resolved <- resolveType defining fixities t
          let spelling = unIdent visible
              printedName = case spelling of
                c:_ | isAlpha c || c == '_' -> spelling
                _ -> "(" ++ spelling ++ ")"
          pure (Just (printedName ++ " :: " ++ showEType resolved))
        [Type lhs t] -> Just . showEDefs . (:[]) . Type lhs <$> resolveType defining fixities t
        _ -> Left ("Ambiguous declaration for " ++ unIdent origin)
      pure (ApiSymbol (unIdent visible) ns (unIdent origin) (showEType checkedType) declared docs)

documentationBefore :: SLoc -> [String] -> Maybe String
documentationBefore (SLoc _ line _) source = collect [] (reverse (take (line - 1) source))
  where
    collect following (previous:rest) = case stripPrefix "--" (dropWhile isSpace previous) of
      Just comment -> case stripPrefix " |" comment of
        Just first -> Just (intercalate "\n" (unspace first : following))
        Nothing -> collect (unspace comment : following) rest
      Nothing -> Nothing
    collect _ [] = Nothing
    unspace (' ':text) = text
    unspace text = text

-- The parser leaves operator precedence unresolved. Use the checker's resolver
-- and fixities before asking its printer for a type.
resolveType :: String -> [(Ident,Fixity)] -> EType -> Either String EType
resolveType defining fixities = go
  where
    go (EOper first rest) = do
      initial <- go first
      remaining <- mapM (\(n,t) -> do
        f <- fixity n
        resolved <- go t
        pure ((EVar n,f),resolved)) rest
      either (Left . snd) Right (resolveFixity initial remaining)
    go (EApp a b) = EApp <$> go a <*> go b
    go (EParen a) = go a
    go (EForall q vs a) = EForall q <$> mapM resolveKind vs <*> go a
    go (ETuple ts) = ETuple <$> mapM go ts
    go (EListish (LList ts)) = EListish . LList <$> mapM go ts
    go (ESign a k) = ESign <$> go a <*> go k
    go t@(EVar _) = Right t
    go t = Left ("Unsupported source type presentation: " ++ showEType t)
    resolveKind (IdKind n k) = IdKind n <$> go k
    fixity n = case lookup n fixities of
      Just f -> Right f
      Nothing -> case lookup (mkIdent (defining ++ "." ++ unIdent n)) fixities of
        Just f -> Right f
        Nothing -> case nub [f | (ident,f) <- fixities, unQualIdent ident == n] of
          [] -> Right defaultFixity
          [f] -> Right f
          _ -> Left ("Ambiguous source type fixity: " ++ unIdent n)
