{-# LANGUAGE GADTs, LambdaCase, OverloadedStrings #-}
module ValidationTests (validationTests) where

import Control.Monad (unless, forM_)
import Data.Aeson (Value(..))
import Data.List (isPrefixOf, isSuffixOf)
import Effectful (Eff, runPureEff)
import Effectful.Dispatch.Dynamic (interpret)
import Kyyn.Domain.Contract
import Kyyn.Domain.DataType
import Kyyn.Domain.Diagnostic
import Kyyn.Domain.Example
import Kyyn.Domain.FileTree
import Kyyn.Domain.Path
import Kyyn.Domain.Query
import Kyyn.Domain.Root
import Kyyn.Types.SchemaMetadata
import Kyyn.Plumbing.Interpreter.DhallHandling
import Kyyn.Porcelain.Capability.RootExecution
import Kyyn.Porcelain.Capability.RootStore
import Kyyn.Porcelain.Capability.Validation
import Kyyn.Porcelain.Interpreter.RootStore

validationTests :: RootContract -> FileTree -> IO ()
validationTests contract facts = do
  let tree = either error id . fileTree
      input = either (error . show) id (checkContract StringType (SchemaMetadata [] [] []))
      result = either (error . show) id (checkContract BoolType (SchemaMetadata [] [] []))
      descriptor = QueryDescriptor "isDone" "Done?" input result
      expectation name requirement expected = Example name descriptor
        (CheckedValue (contractId input) (String "todo-001")) (CheckedValue (contractId result) (Bool expected)) requirement "A completed todo"
      example = expectation "Done 🦋" Required True
      storage operation = runPureEff (runDhallHandling (runRootStore operation))
  encoded <- either (fail . show) pure (storage (encodeExample example))
  let root = Root contract facts encoded
  unless (all (\(p,_) -> "examples/~" `isPrefixOf` relativeName p) (files encoded))
    (fail "Non-ASCII example name was not escaped")
  unless (storage (readExamples root [descriptor]) == Right [example]) (fail "Example round trip changed values or contracts")
  forM_ ["index", "CON", "a/b", "example", "other"] $ \name -> do
    let sample = expectation name Required True
    saved <- either (fail . show) pure (storage (encodeExample sample))
    unless (storage (readExamples (Root contract facts saved) [descriptor]) == Right [sample])
      (fail ("Example path round trip failed: " ++ name))
  let run codeResult semantic actual selected = runPureEff . executionMock selected descriptor codeResult semantic actual
        . runDhallHandling . runRootStore $ checkRoot selected
      semanticWarning = Diagnostic Warning "uncertain" "Check interpretation" Nothing
      semanticError = errorDiagnostic "invalid" "Broken root"
      valid = run (Right ()) (ValidationReport [semanticWarning]) True root
  case valid of
    Passed checked (ValidationReport diagnostics) ->
      unless (validatedValue checked == root && diagnostics == [semanticWarning]) (fail "Validation changed the snapshot/report")
    _ -> fail (show valid)
  case run (Right ()) (ValidationReport []) False root of
    Rejected (ValidationReport [Diagnostic Error "example.mismatch" _ (Just (ExampleLocation "Done 🦋"))]) -> pure ()
    _ -> fail "Required mismatch did not reject validation with its location"
  illustrative <- either (fail . show) pure (storage (encodeExample (expectation "illustration" Illustrative True)))
  case run (Right ()) (ValidationReport [semanticWarning]) False (Root contract facts illustrative) of
    Passed _ (ValidationReport [_, Diagnostic Warning "example.mismatch" _ _]) -> pure ()
    _ -> fail "Illustrative mismatch lost its warning or rejected the root"
  case run (Right ()) (ValidationReport [semanticError]) True root of
    Rejected (ValidationReport [d]) | d == semanticError -> pure ()
    _ -> fail "Semantic error minted validation"
  case run (Left [semanticError]) (error "Compile failure reached validation") (error "Compile failure executed example") root of
    Rejected (ValidationReport [d]) | d == semanticError -> pure ()
    _ -> fail "Compile failure did not reject before checks"
  let incompatible = QueryDescriptor "isDone" "" input input
  case storage (readExamples root [incompatible]) of
    Left [Diagnostic Error _ _ (Just (ExampleLocation "Done 🦋"))] -> pure ()
    _ -> fail "Changed query contract silently rebound the saved example"
  case storage (readExamples root []) of Left _ -> pure (); _ -> fail "Unknown query accepted"
  forM_ [tree (drop 1 (files encoded)), tree ((either error id (relativePath "examples/stray"),"bad") : files encoded),
      tree [(p,if "/expected.dhall" `isSuffixOf` relativeName p then "\"wrong type\"" else b) | (p,b) <- files encoded]] $ \bad ->
    case storage (readExamples (Root contract facts bad) [descriptor]) of
      Left _ -> pure ()
      _ -> fail "Malformed example files accepted"
  let wrong = Example "wrong" descriptor (CheckedValue (contractId result) (Bool True))
        (CheckedValue (contractId result) (Bool True)) Required ""
  case storage (encodeExample wrong) of Left _ -> pure (); _ -> fail "Wrong value contract persisted"
  let noExamples = Root contract facts (tree [])
  case run (Right ()) (ValidationReport []) True noExamples of
    Passed checked _ | validatedValue checked == noExamples -> pure ()
    _ -> fail "Root without examples could not validate"
  putStrLn "Saved example round trips, contract staleness, required/illustrative outcomes and Validated minting passed."

executionMock :: Root -> QueryDescriptor -> Either [Diagnostic] () -> ValidationReport -> Bool
  -> Eff (RootExecution : es) a -> Eff es a
executionMock expectedRoot descriptor codeResult report actual = interpret $ \_ -> \case
  CheckRootCode root -> same root >> pure codeResult
  DiscoverQueries root -> same root >> pure (Right [descriptor])
  ValidateRoot root -> same root >> pure (Right report)
  ExecuteQuery root query _ -> do
    same root
    unless (query == descriptor) (error "Example used an unexpected query descriptor")
    let QueryDescriptor _ _ _ result = descriptor
    pure (Right (QueryResult (CheckedValue (contractId result) (Bool actual)) []))
  where
    same :: Root -> Eff xs ()
    same root = unless (root == expectedRoot) (error "Checking switched root snapshots")
