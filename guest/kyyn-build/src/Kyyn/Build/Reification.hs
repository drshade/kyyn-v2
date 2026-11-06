module Kyyn.Build.Reification (expandSynonyms, recordFields) where

import Language.Haskell.TH

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

-- Instantiate record fields using the compiler's binders, including a concrete
-- alias of a parameterised record. No pretty-printed type is parsed again.
recordFields :: Type -> Q [(Name,Type)]
recordFields selected = do
  expanded <- expandSynonyms selected
  let (headType,arguments) = applications expanded
  case headType of
    ConT name -> reify name >>= \info -> case info of
      TyConI (DataD _ _ variables _ [RecC _ fields] _) -> instantiate variables arguments fields
      TyConI (NewtypeD _ _ variables _ (RecC _ fields) _) -> instantiate variables arguments fields
      _ -> fail "Bindings require a record with one constructor"
    _ -> fail "Bindings require a concrete record type"
  where
    instantiate variables arguments fields
      | length variables == length arguments = pure
          [(name,substitute (zip (map binderName variables) arguments) kind) | (name,_,kind) <- fields]
      | otherwise = fail "Bindings require a fully applied record type"
