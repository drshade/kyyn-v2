{-# LANGUAGE ScopedTypeVariables #-}
{-# OPTIONS_GHC -Werror #-}
module Kyyn.MicroHs.Inspection (InspectionError(..), inspectDataType, inspectModuleImports, inspectPluginSignature, inspectionSettings) where

import Control.DeepSeq (force)
import Control.Exception (SomeException, SomeAsyncException, ErrorCall, catch, evaluate, displayException, fromException, throwIO)
import Control.Monad (unless)
import Data.List (nubBy, nub)
import Kyyn.Domain.DataType
import Kyyn.Domain.Plugin (PluginEntryKind(..), PluginSignature(..), expectedPluginSignature)
import Kyyn.MicroHs.CompilerDiagnostic (compilerMessage)
import Kyyn.MicroHs.Timing (withTimingIO)
import Kyyn.MicroHs.Source (readParsedSource)
import MicroHs.Compile (compileModuleP, addPreludeImport, emptyCache)
import MicroHs.CompileCache (cachedModules)
import MicroHs.Expr hiding (subst)
import MicroHs.Flags
import MicroHs.Ident
import MicroHs.SymTab (Entry(..))
import MicroHs.StateIO (runStateIO)
import MicroHs.TypeCheck (TModule(..), TypeExport(..), ValueExport(..))

data InspectionError
  = TypeNotSupported String
  | CompilerError String
  | NativeError String
  deriving (Eq, Show)

-- Native compiler integration, not a porcelain operation or a complete KB contract.
inspectionFlags :: FilePath -> [FilePath] -> Flags
inspectionFlags compiler sources = defaultFlags { mhsdir = compiler, srcPaths = sources ++ [compiler ++ "/lib"],
  cppArgs = ["-DMIN_VERSION_base(x,y,z)=1"] }

inspectionSettings :: FilePath -> String -> String
inspectionSettings compiler selected = show (selected, inspectionFlags compiler ["<captured>"])

inspectModuleImports :: FilePath -> FilePath -> IO (Either InspectionError [String])
inspectModuleImports compiler path = inspect `catch` failure
  where
    inspect = do
      parsed <- readParsedSource (inspectionFlags compiler []) path
      pure $ case parsed of
        Left message -> Left (CompilerError message)
        Right (EModule _ _ declarations,_) -> Right
          [unIdent name | Import (ImportSpec _ _ name _ _) <- declarations]
    failure (err :: SomeException)
      | Just (_ :: SomeAsyncException) <- fromException err = throwIO err
      | otherwise = pure (Left (NativeError (displayException err)))

inspectDataType :: FilePath -> [FilePath] -> String -> IO (Either InspectionError (DataType, [FilePath]))
inspectDataType compiler sources selected = withTimingIO "inspection" selected (inspect `catch` failure)
  where
    failure (err :: SomeException)
      | Just (_ :: SomeAsyncException) <- fromException err = throwIO err
      | Just (_ :: ErrorCall) <- fromException err = pure (Left (CompilerError (compilerMessage (displayException err))))
      | otherwise = pure (Left (NativeError (displayException err)))
    inspect = do
      let flags = inspectionFlags compiler sources
          witness = addPreludeImport (EModule (mkIdent "KyynTypeWitness")
            [ExpTypeSome (mkIdent "Selected") [mkIdent ".."]]
            [Import (ImportSpec ImpNormal True (mkIdent (definingModule selected)) Nothing Nothing),
             Data (mkIdent "Selected", [])
               [Constr [] [] (mkIdent "Selected") False (Left [(False, EVar (mkIdent selected))])] []])
      (((checked,_,_,_,_),_), cache0) <- runStateIO (compileModuleP flags ImpNormal witness) emptyCache
      (_,cache) <- evaluate (force (checked,cache0))
      let exports = [(unIdent qi, vs) | m <- cachedModules cache,
            TypeExport _ (Entry (EVar qi) _) vs <- tTypeExps m]
          constructors name = maybe [] id (lookup name exports)
      let result = case [fst (arrows (snd (stripForall t))) |
              TypeExport _ _ vs <- tTypeExps checked, ValueExport _ (Entry (ECon _) t) <- vs] of
            [[root]] -> lowerType constructors [] [] root
            _ -> Left "compiler witness did not expose the selected data type"
      forced <- evaluate (force result)
      let loaded = nub [slocFile (slocIdent (tModuleName m)) | m <- cachedModules cache]
      pure (either (Left . TypeNotSupported) (\structure -> Right (structure,loaded)) forced)

type Constructors = String -> [ValueExport]

inspectPluginSignature :: FilePath -> [FilePath] -> PluginEntryKind -> String
  -> IO (Either InspectionError (PluginSignature,[FilePath]))
inspectPluginSignature compiler sources kind selected = withTimingIO "inspection" selected (inspect `catch` failure)
  where
    failure (err :: SomeException)
      | Just (_ :: SomeAsyncException) <- fromException err = throwIO err
      | Just (_ :: ErrorCall) <- fromException err = pure (Left (CompilerError (compilerMessage (displayException err))))
      | otherwise = pure (Left (NativeError (displayException err)))
    inspect = do
      let imported = mkIdent (definingModule selected)
          witness = addPreludeImport (EModule (mkIdent "KyynFunctionWitness") [ExpModule imported]
            [Import (ImportSpec ImpNormal False imported Nothing Nothing)])
      (((checked,_,_,_,_),_),cache0) <- runStateIO (compileModuleP (inspectionFlags compiler sources) ImpNormal witness) emptyCache
      (_,cache) <- evaluate (force (checked,cache0))
      let exports = [(unIdent qi,vs) | m <- cachedModules cache,
            TypeExport _ (Entry (EVar qi) _) vs <- tTypeExps m]
          constructors name = maybe [] id (lookup name exports)
          localName = reverse (takeWhile (/= '.') (reverse selected))
          result = case [signature | ValueExport name (Entry _ signature) <- tValueExps checked,
                                    unIdent name == localName] of
            [signature] -> lowerPluginSignature constructors kind signature
            _ -> Left "selected function is not exported"
      _ <- evaluate (force (show result))
      pure $ case result of
        Left message -> Left (TypeNotSupported (selected ++ ": " ++ message ++ "\nExpected: " ++ expectedPluginSignature kind))
        Right signature -> Right (signature,nub [slocFile (slocIdent (tModuleName m)) | m <- cachedModules cache])

lowerPluginSignature :: Constructors -> PluginEntryKind -> Expr -> Either String PluginSignature
lowerPluginSignature table kind signature = do
  -- These are the pinned compiler's resolved identities, not source-level aliases.
  let (vars,body) = stripForall signature
      (args,result) = arrows body
      lower = lowerType table [] []
      application name arity value = case unApps value of
        (EVar n,xs) | unIdent n == name && length xs == arity -> Right xs
        _ -> Left ("expected " ++ name)
      unary name value = do
        xs <- application name 1 value
        case xs of [x] -> Right x; _ -> Left "invalid unary type"
      pair name value = do
        xs <- application name 2 value
        case xs of [a,b] -> Right (a,b); _ -> Left "invalid binary type"
      named name = EVar (mkIdent name)
      apply name a = EApp (named name) a
      sumType a b = EApp (EApp (named "Kyyn.Types.Program.:+:") a) b
  unless (null vars) (Left "registered entry must have concrete types and no residual constraints")
  (input,options,position,snapshot) <- case (kind,args) of
    (_, [a,s]) -> Right (a,Nothing,Nothing,s)
    (AcquisitionEntry,[a,o,s]) -> case unary "Kyyn.Types.Plugin.FetchContext" o of
      Right p -> Right (a,Nothing,Just p,s)
      Left _ -> do
        option <- unary "Data.Maybe_Type.Maybe" o
        Right (a,Just option,Nothing,s)
    (AcquisitionEntry,[a,o,c,s]) -> do
      option <- unary "Data.Maybe_Type.Maybe" o
      p <- unary "Kyyn.Types.Plugin.FetchContext" c
      Right (a,Just option,Just p,s)
    _ -> Left "unsupported entry arity"
  payload <- unary "Kyyn.Types.Plugin.EvidenceSnapshot" snapshot
  (row,answer) <- pair "Kyyn.Types.Program.Program" result
  let evidenceRow = apply "Kyyn.Types.Plugin.EvidenceRead" payload
      acquisitionRow = foldr sumType evidenceRow (map named
        ["Kyyn.Types.PluginHost.Http","Kyyn.Types.PluginHost.Secrets","Kyyn.Types.PluginHost.Waiting","Kyyn.Types.Plugin.FileRead"])
      expectedRow = case kind of AcquisitionEntry -> acquisitionRow; CapturedReadEntry -> evidenceRow
  unless (eqEType row expectedRow) (Left "unsupported capability row or inconsistent payload")
  (problem,value) <- pair "Data.Either.Either" answer
  unless (eqEType problem (named "Kyyn.Types.Plugin.FetchError")) (Left "expected FetchError failure type")
  case kind of
    AcquisitionEntry -> case position of
      Nothing -> do
        change <- unary "Data.List_Type.[]" value >>= unary "Kyyn.Types.Evidence.EvidenceChange"
        unless (eqEType change payload) (Left "EvidenceChange payload differs from snapshot payload")
        FetchSignature <$> lower input <*> traverse lower options <*> lower payload
      Just p -> do
        (returnedPayload,returnedPosition) <- pair "Kyyn.Types.Plugin.FetchResult" value
        unless (eqEType returnedPayload payload && eqEType returnedPosition p)
          (Left "FetchResult payload/position differs from snapshot/context")
        StatefulFetchSignature <$> lower input <*> traverse lower options <*> lower payload <*> lower p
    CapturedReadEntry -> ReadSignature <$> lower input <*> lower payload <*> lower value

-- Traverses CHECKED constructor signatures. Aliases in them are already expanded
-- by MicroHs. Matching their result against an application substitutes parameters.
lowerType :: Constructors -> [String] -> [(Ident, Expr)] -> Expr -> Either String DataType
lowerType table _ env (EVar n) | Just actual <- lookup n env =
  lowerType table [] [] actual
lowerType table active env original =
  let t = subst env original
      (headType,args) = unApps original
      bad reason = Left reason
  in case (headType,args) of
    -- These identities are specific to the vendored MicroHs revision.
    (EVar n,[]) | unIdent n == "Data.Integer_Type.Integer" -> Right IntegerType
    (EVar n,[]) | unIdent n == "Data.Bool_Type.Bool" -> Right BoolType
    (EVar n,[]) | unIdent n == "Agentic.Questions.Probability" -> Right ProbabilityType
    (EVar n,[]) | unIdent n == "Data.Text.Internal.Text" -> Right TextType
    (EVar n,_) | not (null (unIdent n)) && all (== ',') (unIdent n) -> bad "tuples are outside the data algebra"
    (EVar n,[EVar c]) | unIdent n == "Data.List_Type.[]", unIdent c == "Primitives.Char" -> Right StringType
    (EVar n,[x]) | unIdent n == "Data.List_Type.[]" -> ListType <$> lowerType table active env x
    (EVar n,[x]) | unIdent n == "Data.Maybe_Type.Maybe" -> OptionalType <$> lowerType table active env x
    (EVar n,_) | unIdent n == "Primitives.->" -> bad "function-valued fields are outside the data algebra"
    (EVar n,_) -> do
      let name = unIdent n
      unless (name `notElem` active) (bad ("recursive value embedding is unsupported: " ++ name))
      let cs = nubBy (\(c,_) (d,_) -> conIdent c == conIdent d)
            [(c,ty) | ValueExport _ (Entry (ECon c) ty) <- table name]
      unless (not (null cs)) (bad ("unsupported or opaque type (export constructors): " ++ name))
      argDataTypes <- mapM (lowerType table active env) args
      variants <- mapM (lowerConstructor table (name:active) t) cs
      pure (Algebraic name argDataTypes variants)
    _ -> bad "unsupported higher-rank, constrained or unresolved field type"

lowerConstructor :: Constructors -> [String] -> Expr -> (Con, Expr) -> Either String Constructor
lowerConstructor table active targetType (con,signature) = do
  let (vars,body) = stripForall signature
      (args,result) = arrows body
      regularArgument (EVar n) = n `elem` vars
      regularArgument _ = False
  let parameters = snd (unApps result)
  unless (all regularArgument parameters && length (nub [n | EVar n <- parameters]) == length parameters)
    (Left (showSLoc (getSLoc con) ++ ": indexed GADT constructors are outside the data algebra"))
  bindings <- match vars result targetType
  unless (all (`elem` map fst bindings) vars)
    (Left (showSLoc (getSLoc con) ++ ": existential constructor is outside the data algebra"))
  let names = conFields con
      locations = if null names then repeat (conIdent con) else names
      atDeclaration ident outcome = case outcome of
        Left message -> Left (showSLoc (slocIdent ident) ++ ": " ++ unIdent ident ++ ": " ++ message)
        Right value -> Right value
  fields <- sequence [atDeclaration ident (lowerType table active bindings t) | (ident,t) <- zip locations args]
  unless (null names || length names == length fields)
    (Left "constructor dictionary/GADT field shape is unsupported")
  case con of
    ConSyn{} -> Left "pattern synonyms are not schema constructors"
    _ -> pure (Constructor (unIdent (conIdent con))
           (zip (if null names then repeat Nothing else map (Just . unIdent) names) fields))

stripForall :: Expr -> ([Ident],Expr)
stripForall (EForall _ vs t) = let (rest,b) = stripForall t in (map idKindIdent vs ++ rest,b)
stripForall t = ([],t)

arrows :: Expr -> ([Expr],Expr)
arrows (EApp (EApp (EVar n) a) b) | unIdent n == "Primitives.->" =
  let (as,r) = arrows b in (a:as,r)
arrows t = ([],t)

unApps :: Expr -> (Expr,[Expr])
unApps (EApp f a) = let (h,as) = unApps f in (h,as ++ [a])
unApps t = (t,[])

subst :: [(Ident,Expr)] -> Expr -> Expr
subst env (EVar n) = maybe (EVar n) id (lookup n env)
subst env (EApp f a) = EApp (subst env f) (subst env a)
subst _ t = t

match :: [Ident] -> Expr -> Expr -> Either String [(Ident,Expr)]
match vars (EVar n) t | n `elem` vars = Right [(n,t)]
match _ (EVar n) (EVar m) | n == m = Right []
match vars (EApp f a) (EApp g b) = (++) <$> match vars f g <*> match vars a b
match _ _ _ = Left "constructor result is not a regular applied data type (GADT or wrong arity)"
