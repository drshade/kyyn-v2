{-# LANGUAGE ScopedTypeVariables #-}
module Kyyn.MicroHs.ApiInspection (inspectApi, ApiError(..)) where

import Control.DeepSeq (force)
import Control.Exception (SomeException, SomeAsyncException, ErrorCall, catch, evaluate, displayException, fromException, throwIO)
import Control.Monad (foldM)
import Data.Char (isAlpha, isAlphaNum, isSpace, isSymbol, isPunctuation)
import Data.List (nub, nubBy, sortOn, isPrefixOf, stripPrefix, intercalate, find)
import System.Environment (lookupEnv)
import System.FilePath ((</>))
import System.Process (readProcess)
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
      let cached = cachedModules cache
          names = reverse (sortOn length [unIdent (tModuleName m) | m <- cached])
          origins = [unIdent origin | (_,m,_) <- modules,
            ValueExport _ (Entry expression _) <- tValueExps m ++ concat [xs | TypeExport _ _ xs <- tTypeExps m],
            origin <- case expression of EVar n -> [n]; ECon c -> [conIdent c]; _ -> []]
          owners = [owner | origin <- origins, Just owner <- [find (\n -> (n ++ ".") `isPrefixOf` origin) names]]
      declarations <- mapM (readDeclarations flags)
        [(unIdent (tModuleName m), slocFile (slocIdent (tModuleName m)))
        | m <- cached, "Kyyn." `isPrefixOf` unIdent (tModuleName m) || unIdent (tModuleName m) `elem` owners]
      result <- evaluate (force (sequence declarations >>= \table -> mapM (project table) modules))
      pure (either (Left . ApiSourceError) Right result)
    compile (modules,cache) selectedModule = do
      let imported = mkIdent selectedModule
          witness = addPreludeImport (EModule (mkIdent "KyynApiWitness") [ExpModule imported]
            [Import (ImportSpec ImpNormal False imported Nothing Nothing)])
      (((checked,_,_,_,_),tc),next) <- runStateIO (compileModuleP flags ImpNormal witness) cache
      _ <- evaluate (force checked)
      pure (modules ++ [(selectedModule, checked, IdentMap.toList (fixTable tc))],next)

readDeclarations :: Flags -> (String, FilePath) -> IO (Either String (String, ([EDef],[String])))
readDeclarations flags (name,path) = do
  original <- readFile path
  source <- if hasCpp original then do
    executable <- maybe "cpphs" id <$> lookupEnv "MHSCPPHS"
    readProcess executable (["--strip", "--noline", "-D__MHS__", "-I" ++ (mhsdir flags </> "src/runtime")]
      ++ cppArgs flags ++ [path]) ""
    else pure original
  pure $ case parse pTop path source of
    Left message -> Left message
    Right (EModule _ _ declarations) -> Right (name,(declarations,lines source))

hasCpp :: String -> Bool
hasCpp [] = False
hasCpp ('{':'-':'#':rest) =
  let (pragma,following) = span (/= '#') rest
  in "CPP" `elem` words (map (\c -> if c == ',' then ' ' else c) pragma) || hasCpp following
hasCpp (_:rest) = hasCpp rest

project :: [(String,([EDef],[String]))] -> (String,TModule a,[(Ident,Fixity)]) -> Either String ApiModule
project declarations (selected,checked,fixities) = do
  types <- mapM typeSymbol (tTypeExps checked)
  values <- mapM valueSymbol [v | v@(ValueExport name _) <- tValueExps checked ++ concat
    [associated | TypeExport _ _ associated <- tTypeExps checked], sourceName (unIdent name)]
  pure (ApiModule selected (sortOn key (nubBy (\a b -> key a == key b) (types ++ values))))
  where
    key (ApiSymbol n ns origin _ _ _) = (n,ns,origin)
    exportedConstructors = [conIdent c | ValueExport _ (Entry (ECon c) _) <-
      tValueExps checked ++ concat [xs | TypeExport _ _ xs <- tTypeExps checked]]
    typeSymbol (TypeExport n entry _) = symbol TypeNamespace n entry
    valueSymbol (ValueExport n entry) = symbol ValueNamespace n entry
    symbol ns visible (Entry expression checkedType) = do
      origin <- case expression of
        EVar ident -> Right ident
        ECon constructor -> Right (conIdent constructor)
        _ -> Left ("Unsupported exported entry: " ++ unIdent visible)
      let defining = case [owner | (owner,_) <- declarations, (owner ++ ".get$.") `isPrefixOf` unIdent origin] of
            [owner] -> owner
            _ -> unIdent (qualOf origin)
          (defs,sourceLines) = maybe ([],[]) id (lookup defining declarations)
          algebraic = concatMap (\d -> case d of
            Data lhs cs _ -> [presentationVariables lhs cs]
            Newtype lhs c _ -> [presentationVariables lhs [c]]
            _ -> []) defs
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
              ++ [Sign [visible] (constructorType lhs c) | (lhs,cs) <- algebraic,
                  c@(Constr _ _ n _ _) <- cs, n == unQualIdent origin]
              ++ [Sign [visible] (arrow (lhsToType lhs) fieldType) | (lhs,cs) <- algebraic,
                  Constr _ _ _ _ (Right fs) <- cs, (field,(_,fieldType)) <- fs,
                  unIdent origin == defining ++ ".get$." ++ unIdent (fst lhs) ++ "." ++ unIdent field]
            TypeNamespace -> concatMap (\d -> case d of
              Type (n,args) t | n == unQualIdent origin -> [Type (visible,args) t]
              Data (n,args) cs ds | n == unQualIdent origin -> [Data (visible,args) cs ds]
              Newtype (n,args) c ds | n == unQualIdent origin -> [Newtype (visible,args) c ds]
              _ -> []) defs
      declared <- case nubBy sameSignature matches of
        [] -> Right Nothing
        [Sign _ t] -> do
          resolved <- resolveType defining fixities t
          let spelling = unIdent visible
              printedName = case spelling of
                c:_ | isAlpha c || c == '_' -> spelling
                _ -> "(" ++ spelling ++ ")"
          pure (Just (printedName ++ " :: " ++ showEType resolved))
        [Type lhs t] -> Just . showEDefs . (:[]) . Type lhs <$> resolveType defining fixities t
        [Data lhs cs _] -> Just <$> presentData defining lhs cs False
        [Newtype lhs c _] -> Just <$> presentData defining lhs [c] True
        _ -> Left ("Ambiguous declaration for " ++ unIdent origin)
      pure (ApiSymbol (unIdent visible) ns (unIdent origin) (showEType checkedType) declared docs)
    sameSignature (Sign ns a) (Sign ns' b) = ns == ns' && eqEType a b
    sameSignature _ _ = False
    presentData defining originalLhs originalCs isNewtype = do
      let (lhs,cs) = presentationVariables originalLhs originalCs
      let public (Constr _ _ n _ _) = mkIdent (defining ++ "." ++ unIdent n) `elem` exportedConstructors
          fields = [unIdent n | TypeExport _ (Entry (EVar origin) _) xs <- tTypeExps checked,
            origin == mkIdent (defining ++ "." ++ unIdent (fst lhs)), ValueExport n _ <- xs]
      constructors <- mapM (resolveConstructor defining fields) (filter public cs)
      let headerLhs = if any refinesRoot constructors then
            (fst originalLhs, [IdKind (mkIdent (takeWhile (/= '$') (unIdent n))) k | IdKind n k <- snd originalLhs])
            else lhs
          dataHeader = unwords (words (showEDefs [Data headerLhs [] []]))
          header = if isNewtype then "newtype" ++ drop 4 dataHeader else dataHeader
          refinesRoot (Constr _ ctx _ _ _) = any (\constraint -> case constraint of
            EApp (EApp (EVar equal) (EVar variable)) _ ->
              unIdent equal == "~" && variable `elem` map idKindIdent (snd lhs)
            _ -> False) ctx
      if any refinesRoot constructors then do
        signatures <- mapM (\c@(Constr _ _ n _ _) -> do
          t <- resolveType defining fixities (constructorType lhs c)
          pure ("  " ++ unIdent n ++ " :: " ++ showEType t)) constructors
        pure (header ++ " where\n" ++ intercalate "\n" signatures)
      else pure (header ++ if null constructors then "" else " = " ++ intercalate " | " (map presentConstructor constructors))
    resolveConstructor defining publicFields (Constr vs ctx n inf fields) = do
      let resolve = resolveType defining fixities
          argument (strict,t) = do
            resolved <- resolve t
            pure (strict, case resolved of
              EVar _ -> resolved
              ETuple _ -> resolved
              EListish _ -> resolved
              _ -> EParen resolved)
      vs' <- mapM (\(IdKind v k) -> IdKind v <$> resolve k) vs
      ctx' <- mapM resolve ctx
      fields' <- case fields of
        Left ts -> Left <$> mapM argument ts
        Right fs | all (\(label,_) -> unIdent label `elem` publicFields) fs ->
          Right <$> mapM (\(label,t@(strict,fieldType)) -> (,) label <$>
            if strict then argument t else (,) False <$> resolve fieldType) fs
        Right fs -> Left <$> mapM (argument . snd) fs
      pure (Constr vs' ctx' n inf fields')

arrow :: EType -> EType -> EType
arrow = eAppI2 (mkIdent "->")

constructorType :: LHS -> Constr -> EType
constructorType lhs (Constr _ constraints _ _ fields) =
  let parameters = map idKindIdent (snd lhs)
      solve (known,pending) constraint = case subst known constraint of
        EApp (EApp (EVar equal) (EVar variable)) rhs
          | unIdent equal == "~", variable `elem` parameters,
            variable `notElem` allVarsExpr rhs ->
              ((variable,rhs) : [(v,subst [(variable,rhs)] t) | (v,t) <- known], pending)
        other -> (known,pending ++ [other])
      (substitutions,remaining) = foldl solve ([],[]) constraints
      arguments = map snd (either id (map snd) fields)
      body = subst substitutions (foldr arrow (lhsToType lhs) arguments)
      context = map (subst substitutions) remaining
  in if null context then body else eAppI2 (mkIdent "=>") (ETuple context) body

sourceName :: String -> Bool
sourceName [] = False
sourceName name@(first:rest)
  | isAlpha first || first == '_' = all (\c -> isAlphaNum c || c `elem` "_'") rest
  | otherwise = all operator name && name `notElem` ["..", ":", "::", "=", "\\", "|", "<-", "->", "@", "~", "=>"]
  where
    operator c = (isSymbol c || isPunctuation c) && c `notElem` "_\"'`()[]{},;"

-- Parsing a GADT introduces dollar-suffixed root parameters. Give those
-- parameters fresh source identifiers before printing their lowered form.
presentationVariables :: LHS -> [Constr] -> (LHS, [Constr])
presentationVariables (name,args) constructors = ((name,map variable args),map constructor constructors)
  where
    expressions = [t | Constr _ ctx _ _ fs <- constructors,
      t <- ctx ++ map snd (either id (map snd) fs)]
    occupied = map unIdent (concatMap allVarsExpr expressions
      ++ [v | Constr vs _ _ _ _ <- constructors, IdKind v _ <- vs])
    generated = [v | IdKind v _ <- args, '$' `elem` unIdent v]
    allocate _ [] = []
    allocate used (v:rest) =
      let authored = takeWhile (/= '$') (unIdent v)
          candidate = head [n | n <- authored : map (:[]) ['a'..'z']
                ++ [letter : show i | i <- [1 :: Int ..], letter <- ['a'..'z']], n `notElem` used]
      in (v,EVar (mkIdent candidate)) : allocate (candidate:used) rest
    substitutions = allocate occupied generated
    rename v = case lookup v substitutions of Just (EVar n) -> n; _ -> v
    variable (IdKind v k) = IdKind (rename v) (subst substitutions k)
    field (strict,t) = (strict,subst substitutions t)
    constructor (Constr vs ctx n inf fs) = Constr (map variable vs)
      (map (subst substitutions) ctx) n inf
      (either (Left . map field) (Right . map (\(label,t) -> (label,field t))) fs)

presentConstructor :: Constr -> String
presentConstructor (Constr vs ctx n _ fields) = quantifier ++ context ++ name ++ arguments
  where
    name = case unIdent n of
      s@(c:_) | isAlpha c || c == '_' -> s
      s -> "(" ++ s ++ ")"
    quantifier = if null vs then "" else "forall " ++ unwords (map variable vs) ++ ". "
    variable (IdKind v (EVar k)) | isDummyIdent k = unIdent v
    variable (IdKind v k) = "(" ++ unIdent v ++ " :: " ++ showEType k ++ ")"
    context = if null ctx then "" else showEType (ETuple ctx) ++ " => "
    fieldType (strict,t) = (if strict then "!" else "") ++ showEType t
    arguments = case fields of
      Left [] -> ""
      Left ts -> " " ++ unwords (map fieldType ts)
      Right fs -> " { " ++ intercalate ", " [unIdent label ++ " :: " ++ fieldType t | (label,t) <- fs] ++ " }"

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
