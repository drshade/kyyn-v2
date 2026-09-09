{-# LANGUAGE DataKinds, GADTs, LambdaCase, OverloadedStrings #-}
module InitializationTests (initializationTests) where

import Control.Monad (unless)
import Data.Aeson (object)
import Effectful (Eff, runPureEff)
import Effectful.Dispatch.Dynamic (interpret)
import Kyyn.Domain.Contract (checkContract, checkRootLayout)
import Kyyn.Domain.DataType
import Kyyn.Domain.Diagnostic
import Kyyn.Domain.FileTree (fileTree, files)
import Kyyn.Domain.Git
import Kyyn.Domain.KnowledgeBase (KnowledgeBase(..))
import Kyyn.Domain.Path
import Kyyn.Domain.Publication
import Kyyn.Domain.Root (Root)
import Kyyn.Types.SchemaMetadata
import Kyyn.Porcelain.Capability.KnowledgeBaseInitialization
import Kyyn.Porcelain.Capability.RootOpening
import Kyyn.Porcelain.Capability.RootExecution
import Kyyn.Porcelain.Capability.RootStore
import Kyyn.Porcelain.RootExecution.Types (PreparedRoot(..))
import Kyyn.Porcelain.Validated (validatedValue)
import Kyyn.Porcelain.Interpreter.RootStore
import Kyyn.Plumbing.Interpreter.DhallHandling

initializationTests :: IO ()
initializationTests = do
  initial <- either fail pure initialRootFiles
  code <- either fail pure (fileTree [(p,b) | (p,b) <- files initial, relativeName p /= "facts/root.dhall"])
  contract <- either (fail . show) pure (checkContract
    (Algebraic "RootV1.Root" [] [Constructor "RootV1.Root" []]) (SchemaMetadata [] [] []) >>= checkRootLayout)
  root <- either (fail . show) pure $ runPureEff . runDhallHandling . runRootStore $ do
    checked <- checkRootValue contract (object [])
    either (pure . Left) (materializeRoot contract code) checked
  scope <- either fail pure (directoryScope "/unused-initialization-test")
  revision <- either fail pure (gitRevision (replicate 40 'a'))
  let target = InitializationTarget scope scope Nothing
      identity = CommitIdentity "Test" "test@example.invalid" "1700000000 +0000"
      metadata = CommitMetadata identity identity "Initialize"
      initialized = InitializedRoot revision (LocalBranch "main") (KnowledgeBase (Repository scope) WholeTree) WorkingTreeUpdated
      execute report = runPureEff . runDhallHandling . runRootStore
        . opening root . checking root report . publication target metadata root initialized report $
          initializeKnowledgeBase target metadata
      good = ValidationReport []
      bad = ValidationReport [errorDiagnostic "test.invalid" "Root is invalid"]
  unless (execute good == Passed initialized good) (fail "Valid initialization did not publish the checked root")
  unless (execute bad == Rejected bad) (fail "Invalid initialization was published")
  putStrLn "Initialization workflow requires successful root validation before publication."

opening :: Root -> Eff (RootOpening : es) a -> Eff es a
opening root = interpret $ \_ -> \case
  OpenCapturedRoot actual | Right actual == initialRootFiles -> pure (Right root)
  _ -> error "Initialization did not open its pure scaffold"

checking :: Root -> ValidationReport -> Eff (RootExecution : es) a -> Eff es a
checking expected report = interpret $ \_ -> \case
  PrepareRoot root | root == expected -> pure (Right (PreparedRoot root "Validate.validate" (error "Test must not execute bytecode") []))
  ValidateRoot root | preparedRoot root == expected -> pure (Right report)
  _ -> error "Initialization checked a different root or ran a query"

publication :: InitializationTarget -> CommitMetadata -> Root -> InitializationResult -> ValidationReport
  -> Eff (KnowledgeBaseInitialization : es) a -> Eff es a
publication target metadata expected initialized report = interpret $ \_ -> \case
  PublishInitialRoot actual commit root
    | report == ValidationReport [] && actual == target && commit == metadata && validatedValue root == expected -> pure (Right initialized)
  _ -> error "Initialization published without successful validation or changed its inputs"
