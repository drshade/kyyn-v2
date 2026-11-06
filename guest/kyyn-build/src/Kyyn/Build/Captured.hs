{-# LANGUAGE TemplateHaskell, OverloadedRecordDot #-}
-- Private build tooling. Generated modules call these splices; KB authors use
-- the resulting typed proxies and never maintain a parallel signature registry.
module Kyyn.Build.Captured (CapturedBinding(..), capturedCalls) where

import Control.Monad (forM)
import Data.List (nub)
import Language.Haskell.TH
import Agentic.Contract (Contract)
import Kyyn.Types.Program (Program, Member, inject, request, (:+:))
import Kyyn.Types.Plugin (ConnectorInstance, EvidenceSnapshot, EvidenceRead, FetchError)
import Kyyn.Types.Blob (BlobRead)

data CapturedBinding = CapturedBinding
  { constructorName :: Name, proxyName :: Name, connectorName :: Name
  , implementationName :: Name, authoredSource :: String }

capturedCalls :: Name -> [CapturedBinding] -> Q [Dec]
capturedCalls calls bindings = do
  methods <- forM bindings $ \binding -> do
    signature <- reifyType binding.implementationName >>= expandSynonyms
    (argument,result) <- case capturedTypes signature of
      Just types -> pure types
      Nothing -> do
        reportError (binding.authoredSource ++ ": " ++ pprint binding.implementationName ++
          ": expected Input -> EvidenceSnapshot Payload -> CapturedRead Payload (Either FetchError Result); got " ++ pprint signature)
        fail "Invalid registered captured-read method"
    row <- newName "row"
    instanceValue <- newName "instanceValue"
    arguments <- newName "arguments"
    let instanceType = AppT (ConT ''ConnectorInstance) (ConT binding.connectorName)
        resultType = AppT (AppT (ConT ''Either) (ConT ''FetchError)) result
        contracts = map (AppT (ConT ''Contract)) [argument,result]
        constructor = ForallC [] contracts (GadtC [binding.constructorName]
          [(plain,instanceType),(plain,argument)] (AppT (ConT calls) resultType))
        proxyType = ForallT [PlainTV row SpecifiedSpec]
          (contracts ++ [AppT (AppT (ConT ''Member) (ConT calls)) (VarT row)])
          (arrow instanceType (arrow argument (AppT (AppT (ConT ''Program) (VarT row)) resultType)))
        body = AppE (VarE 'request) (AppE (VarE 'inject)
          (AppE (AppE (ConE binding.constructorName) (VarE instanceValue)) (VarE arguments)))
    pure (constructor,[SigD binding.proxyName proxyType,
      FunD binding.proxyName [Clause [VarP instanceValue,VarP arguments] (NormalB body) []]])
  result <- newName "result"
  let tags = [DataD [] tag [] Nothing [] [] | tag <- nub (map connectorName bindings)]
      algebra = DataD [] calls [PlainTV result BndrReq] Nothing (map fst methods) []
  pure (tags ++ [algebra] ++ concatMap snd methods)
  where plain = Bang NoSourceUnpackedness NoSourceStrictness

capturedTypes :: Type -> Maybe (Type,Type)
capturedTypes signature = case signature of
  AppT (AppT ArrowT argument) (AppT (AppT ArrowT (AppT (ConT snapshot) payload))
    (AppT (AppT (ConT program) row) (AppT (AppT (ConT eitherType) (ConT problem)) result)))
    | snapshot == ''EvidenceSnapshot, program == ''Program, eitherType == ''Either, problem == ''FetchError
    , row == AppT (AppT (ConT ''(:+:)) (AppT (ConT ''EvidenceRead) payload)) (ConT ''BlobRead)
    -> Just (argument,result)
  _ -> Nothing

arrow :: Type -> Type -> Type
arrow input output = AppT (AppT ArrowT input) output

-- Synonym expansion uses resolved compiler Names. In particular, Text and other
-- library types keep their actual identity without printing private module names
-- into imports or parsing pretty-printed signatures back into a type.
expandSynonyms :: Type -> Q Type
expandSynonyms value = do
  let (headType,arguments) = applications value
  expanded <- traverse expandSynonyms arguments
  case headType of
    ConT name -> reify name >>= \info -> case info of
      TyConI (TySynD _ variables body) | length expanded >= length variables ->
        expandSynonyms (foldl AppT (substitute (zip (map binderName variables) expanded) body)
          (drop (length variables) expanded))
      _ -> pure (foldl AppT headType expanded)
    SigT inner _ -> expandSynonyms (foldl AppT inner expanded)
    _ -> pure (foldl AppT headType expanded)

applications :: Type -> (Type,[Type])
applications = go []
  where
    go arguments (AppT function argument) = go (argument:arguments) function
    go arguments value = (value,arguments)

binderName :: TyVarBndr flag -> Name
binderName (PlainTV name _) = name
binderName (KindedTV name _ _) = name

substitute :: [(Name,Type)] -> Type -> Type
substitute bindings value = case value of
  VarT name -> maybe value id (lookup name bindings)
  AppT function argument -> AppT (substitute bindings function) (substitute bindings argument)
  SigT inner kind -> SigT (substitute bindings inner) kind
  ForallT variables context body ->
    let remaining = filter ((`notElem` map binderName variables) . fst) bindings
    in ForallT variables (map (substitute remaining) context) (substitute remaining body)
  _ -> value
