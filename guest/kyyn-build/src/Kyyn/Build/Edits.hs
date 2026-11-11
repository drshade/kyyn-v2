{-# LANGUAGE TemplateHaskell #-}
module Kyyn.Build.Edits (rootEdits, targetFields) where

import Control.Monad (forM, unless)
import Data.List (nub)
import qualified Data.Text as Text
import GHC.Generics (Generic)
import Agentic.Contract (Contract)
import Language.Haskell.TH
import Kyyn.Types.Fact (Fact)
import Kyyn.Build.Reification (expandSynonyms, recordFields)

-- Root is compiled before this generated module. Payload Names come from GHC,
-- so record fields and payload types need not have public selector exports.
rootEdits :: Name -> [(String,String)] -> Q [Dec]
rootEdits root collections = do
  fields <- if null collections then pure [] else recordFields (ConT root)
  unless (length (map snd collections) == length (nub (map snd collections)))
    (fail "Duplicate collection field in fact edit bindings")
  selected <- forM collections $ \(collection,field) -> do
    fieldType <- case [kind | (name,kind) <- fields, nameBase name == field] of
      [kind] -> expandSynonyms kind
      _ -> fail ("No Root field for collection " ++ collection ++ ": " ++ field)
    payload <- case fieldType of
      AppT ListT (AppT (ConT fact) value) | fact == ''Fact -> pure value
      _ -> fail ("Collection " ++ collection ++ " must contain [Fact payload]")
    let constructor = mkName ("Edit_" ++ field)
        operation = mkName "operation"
        optic = AppTypeE (VarE (mkName "Optics.field")) (LitT (StrTyLit field))
        handle = AppE (AppE (VarE (mkName "Bindings.collection")) (AppE (VarE 'Text.pack) (LitE (StringL collection)))) optic
        body = AppE (AppE (VarE (mkName "Edit.within")) handle)
          (AppE (VarE (mkName "Proposal.applyFactEdit")) (VarE operation))
    pure (NormalC constructor [(Bang NoSourceUnpackedness NoSourceStrictness,AppT (ConT (mkName "Proposal.FactEdit")) payload)],
      Clause [ConP constructor [] [VarP operation]] (NormalB body) [])
  let name = mkName "RootEdit"
      apply = mkName "applyRootEdit"
      unit = TupleT 0
      edit = AppT (AppT (ConT (mkName "Edit.Edit")) (ConT root)) unit
      derives = [DerivClause (Just StockStrategy) [ConT ''Generic]] ++
        [DerivClause (Just AnyclassStrategy) [ConT ''Contract] | not (null selected)]
      empty = mkName "impossible"
      clauses = if null selected then [Clause [VarP empty] (NormalB (CaseE (VarE empty) [])) []] else map snd selected
  pure [DataD [] name [] Nothing (map fst selected) derives,
    SigD apply (AppT (AppT ArrowT (ConT name)) edit),FunD apply clauses]

-- Residual handles are selected from the actual target record, not authored DTOs.
targetFields :: Name -> [String] -> Q [Dec]
targetFields root collections = do
  fields <- recordFields (ConT root)
  pure (concat
    [[SigD (mkName (nameBase name)) (AppT (AppT (ConT (mkName "Preparation.TargetField")) (ConT root)) kind),
      ValD (VarP (mkName (nameBase name)))
        (NormalB (AppE (ConE (mkName "Preparation.TargetField"))
          (AppE (VarE 'Text.pack) (LitE (StringL (nameBase name)))))) []]
    | (name,kind) <- fields, nameBase name `notElem` collections])
