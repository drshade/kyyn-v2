module Kyyn.Porcelain.Capability.Validation (checkRoot, checkPreparedRoot, checkCandidate, checkExample) where

import Effectful (Eff, (:>))
import Kyyn.Domain.Contract (contractId)
import Kyyn.Domain.Diagnostic
import Kyyn.Domain.Example (Example(..), ExampleRequirement(..))
import Kyyn.Domain.Evolution (Candidate(..))
import Kyyn.Domain.Query (QueryDescriptor(..), QueryResult(..))
import Kyyn.Domain.Root (Root, CheckedValue(..))
import Kyyn.Porcelain.Capability.RootExecution (RootExecution, PreparedRoot, prepareRoot, preparedRoot, preparedQueries, queryRoot, validateRoot)
import Kyyn.Porcelain.Capability.RootStore (RootStore, readExamples)
import Kyyn.Porcelain.Validation.Types (Validated(..))

checkCandidate :: (RootExecution :> es, RootStore :> es)
  => Candidate Root -> Eff es (CheckResult (Candidate (Validated Root)))
checkCandidate (Candidate context report root) = do
  result <- checkRoot root
  pure $ case result of
    Rejected diagnostics -> Rejected diagnostics
    Passed checked diagnostics -> Passed (Candidate context report checked) diagnostics

checkRoot :: (RootExecution :> es, RootStore :> es) => Root -> Eff es (CheckResult (Validated Root))
checkRoot root = do
  code <- prepareRoot root
  case code of
    Left diagnostics -> pure (Rejected (ValidationReport diagnostics))
    Right prepared -> checkPreparedRoot prepared

checkPreparedRoot :: (RootExecution :> es, RootStore :> es) => PreparedRoot -> Eff es (CheckResult (Validated Root))
checkPreparedRoot prepared = do
  let root = preparedRoot prepared
  loaded <- readExamples root (preparedQueries prepared)
  case loaded of
    Left diagnostics -> pure (Rejected (ValidationReport diagnostics))
    Right examples -> do
      semantic <- validateRoot prepared
      case semantic of
        Left diagnostics -> pure (Rejected (ValidationReport diagnostics))
        Right (ValidationReport diagnostics) -> do
          reports <- traverse (checkExample prepared) examples
          let combined = diagnostics ++ concat [ds | ValidationReport ds <- reports]
          pure (checkReport (Validated root) (ValidationReport combined))

checkExample :: RootExecution :> es => PreparedRoot -> Example -> Eff es ValidationReport
checkExample root (Example name descriptor@(QueryDescriptor _ _ input result)
    arguments@(CheckedValue inputId _) (CheckedValue expectedId expected) requirement _) =
  if inputId /= contractId input || expectedId /= contractId result
    then pure (ValidationReport [diagnostic Error "example.contract" "Example values belong to different query contracts"])
    else do
      response <- queryRoot root descriptor arguments
      pure $ case response of
        Left diagnostics -> ValidationReport (map locate diagnostics)
        Right (QueryResult (CheckedValue actualId actual) _)
          | actualId /= expectedId -> ValidationReport [diagnostic Error "example.contract" "Query returned a different result contract"]
          | actual == expected -> ValidationReport []
          | otherwise -> ValidationReport [diagnostic (case requirement of Required -> Error; Illustrative -> Warning)
              "example.mismatch" ("Expected " ++ show expected ++ "; received " ++ show actual)]
  where
    diagnostic level code message = Diagnostic level code message (Just (ExampleLocation name))
    locate (Diagnostic level code message _) = diagnostic level code message
