{-# LANGUAGE TemplateHaskell #-}
module Kyyn.Build.RecipeTypes (flowStateAlias, flowDefinition, flowDefinitions, optionalStateDefinition) where

import Control.Monad (unless)
import qualified Agentic as A
import Agentic.Contract (Contract)
import Language.Haskell.TH
import Kyyn.Build.Reification (expandSynonyms)

-- Compiler Names preserve private state types. Generated imports supply the SDK
-- names without adding an SDK/runtime dependency to the compiler helper package.
flowState :: Name -> Name -> Q Type
flowState root implementation = do
  signature <- reifyType implementation >>= expandSynonyms
  inputName <- required "Recipe.RecipeInput"
  proposalName <- required "Recipe.RecipeProposal"
  expected <- expandSynonyms (ConT root)
  case signature of
    AppT (AppT (AppT (ConT flow) _) (AppT (AppT (AppT (ConT request) actualRoot) _) state))
        (AppT (AppT (ConT proposal) _) next)
      | flow == ''A.Agentic, request == inputName, proposal == proposalName -> do
          unless (actualRoot == expected) (fail "Recipe flow uses a different Root type")
          unless (state == next) (fail "Recipe flow changes its state type")
          pure state
    _ -> fail ("Expected a concrete recipe Flow at " ++ show implementation ++ "; got " ++ pprint signature)
  where
    required name = lookupTypeName name >>= maybe (fail ("Generated recipe module is missing import " ++ name)) pure

flowStateAlias :: Name -> Name -> Name -> Q [Dec]
flowStateAlias alias root implementation = do
  state <- flowState root implementation
  pure [TySynD alias [] state]

flowDefinition :: Name -> Name -> Name -> String -> Q [Dec]
flowDefinition binding root implementation reference = do
  state <- flowState root implementation
  supported <- isInstance ''Contract [state]
  unless supported (fail "Recipe state has no Contract instance")
  definition <- lookupTypeName "RecipeDefinition" >>= maybe (fail "Missing RecipeDefinition import") pure
  let selected = AppE (AppTypeE (VarE (mkName "Bindings.closedRecipe")) state) (LitE (StringL reference))
      body = AppE (AppE (AppE (VarE 'either) (InfixE (Just (VarE 'error)) (VarE '(.)) (Just (VarE 'show)))) (VarE 'id)) selected
  pure [SigD binding (AppT (ConT definition) state),ValD (VarP binding) (NormalB body) []]

-- A module can export ordinary helpers alongside recipe flows. GHC reification
-- determines eligible flows; printed signatures are never parsed for identity.
flowDefinitions :: Name -> [(String,Name,String)] -> Q [Dec]
flowDefinitions root candidates = concat <$> traverse
  (\(binding,implementation,reference) -> recover (pure []) (flowDefinition (mkName binding) root implementation reference)) candidates

-- Stored open-state references are optional candidates, not imports demanded by
-- the evolution author. A target type without Contract is unresolved data.
optionalStateDefinition :: Name -> Name -> String -> Q [Dec]
optionalStateDefinition binding state reference = recover (pure []) $ do
  kind <- expandSynonyms (ConT state)
  supported <- isInstance ''Contract [kind]
  unless supported (fail "Stored state candidate has no Contract instance")
  let selected = AppE (AppTypeE (VarE (mkName "Bindings.recipeType")) kind) (LitE (StringL reference))
      body = AppE (AppE (AppE (VarE 'either) (InfixE (Just (VarE 'error)) (VarE '(.)) (Just (VarE 'show)))) (VarE 'id)) selected
  pure [SigD binding (AppT (ConT (mkName "RecipeType")) kind),ValD (VarP binding) (NormalB body) []]
