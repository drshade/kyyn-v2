{-# LANGUAGE GADTs #-}
module Kyyn.Porcelain.Interpreter.EvolutionExecution (runEvolutionExecution) where

import Control.Monad (unless)
import Control.Monad.Trans.Except (ExceptT(..), runExceptT, throwE)
import Data.Aeson (encode)
import qualified Data.ByteString as Strict
import qualified Data.ByteString.Lazy as Bytes
import Data.List (nub)
import Effectful (Eff, (:>))
import Effectful.Dispatch.Dynamic (interpret)
import Kyyn.Domain.Contract (RootContract, checkRootLayout)
import Kyyn.Domain.Diagnostic (Diagnostic, errorDiagnostic)
import Kyyn.Domain.Evolution
import Kyyn.Domain.FileTree (FileTree, files, fileTree)
import Kyyn.Domain.Git (TreePath(..))
import Kyyn.Domain.KnowledgeBase (KnowledgeBase(..))
import Kyyn.Domain.Path (RelativePath)
import Kyyn.Domain.Root (Root(..), RootDefinition(..), CheckedValue(..))
import Kyyn.Domain.Workspace (WorkspaceSnapshot(..), WorkspaceManifest(..), IntermediateBinding(..))
import Kyyn.Domain.Failure (OperationalFailure(..), ProcessDiagnostic(..), ProcessOperation(..))
import Kyyn.Plumbing.Capability.Failure (Failure, raiseFailure)
import Kyyn.Plumbing.Capability.FileSystem (FileSystem)
import Kyyn.Plumbing.Capability.GuestCompilation (GuestCompilation, compileGuest, executeCompiledEntry)
import Kyyn.Plumbing.Capability.ProcessExecution (ProcessExecution)
import qualified Kyyn.Plumbing.Capability.SchemaInspection as Schema
import Kyyn.Plumbing.Protocol.Evolution (evolutionSources, decodeEvolutionReply)
import Kyyn.Porcelain.Capability.EvolutionExecution (EvolutionExecution(..))
import Kyyn.Porcelain.Capability.EvolutionReport (checkEvolutionReport)
import qualified Kyyn.Porcelain.Capability.RootOpening as RootOpening
import Kyyn.Porcelain.Capability.RootStore (RootStore, readRootDefinition, loadRootValueForChecking, rootLocation)

runEvolutionExecution
  :: (RootStore :> es, RootOpening.RootOpening :> es, Schema.SchemaInspection :> es,
      GuestCompilation :> es, FileSystem :> es, ProcessExecution :> es, Failure :> es)
  => FileTree -> Eff (EvolutionExecution : es) a -> Eff es a
runEvolutionExecution sdk = interpret $ \_ (EvaluateEvolution captured@(CapturedEvolution
    (EvolutionContext kb@(KnowledgeBase repository _) _ (Before revision expected)
      (WorkspaceSnapshot (WorkspaceManifest _ _ _ _ declarations) before target change _)))) -> runExceptT $ do
  rootPath <- checked "evolution.before-path" (rootLocation kb)
  source@(Root actual _ acceptedCode) <- proposed (RootOpening.loadRootAt repository revision (Subtree rootPath))
  unless (actual == expected) (reject "evolution.before-contract" "Before's contract changed; capture the evolution again")
  RootDefinition beforeType beforeMetadata _ _ acceptedSources <- proposed (readRootDefinition acceptedCode)
  unless (before == acceptedSources) (reject "evolution.before-source" "Captured before/ differs from the selected revision's source")
  CheckedValue _ input <- proposed (loadRootValueForChecking source)
  (inspectedBefore,closure) <- inspect (files before ++ files sdk) beforeType beforeMetadata
  unless (inspectedBefore == expected) (reject "evolution.before-contract" "Before inspection differs from its captured contract")
  RootDefinition targetType targetMetadata _ _ targetSources <- proposed (readRootDefinition target)
  (after,_) <- inspect (files targetSources ++ files sdk) targetType targetMetadata
  old <- checked "evolution.before-closure" (fileTree [(p,b) | (p,b) <- files before, p `elem` closure])
  combined <- checked "evolution.source-collision" (mergeSources [old,targetSources,change,sdk])
  intermediates <- traverse (\(IntermediateBinding name selected metadata) -> do
    (contract,_) <- inspect (files combined) selected metadata
    pure (name,contract)) declarations
  prepared <- checked "evolution.prepare" (evolutionSources expected after intermediates combined)
  compiled <- proposed (compileGuest prepared)
  output <- ExceptT (Right <$> executeCompiledEntry "Evolution.evolution" compiled (Bytes.toStrict (encode input)))
  reply <- case decodeEvolutionReply output of
    Left message -> ExceptT (raiseFailure (RuntimeUnavailable (ProcessDiagnostic ReadOutput
      ("Evolution.evolution: " ++ message))))
    Right (Left failure) -> throwE (EvolutionRejected failure)
    Right (Right result) -> pure result
  result <- proposed (checkEvolutionReport (map snd intermediates) expected input after reply)
  let (value,report) = result
  pure (EvaluatedEvolution captured (After after) value report)

inspect :: Schema.SchemaInspection :> es
  => [(RelativePath,Strict.ByteString)] -> String -> String -> ExceptT PreviewRejection (Eff es) (RootContract, [RelativePath])
inspect sources selected metadata = do
  source <- checked "evolution.schema-source" (Schema.schemaSource sources selected metadata)
  Schema.InspectedSchema contract closure <- proposed (Schema.inspectSchema source)
  root <- proposed (pure (checkRootLayout contract))
  pure (root,closure)

mergeSources :: [FileTree] -> Either String FileTree
mergeSources trees = case fileTree (nub (concatMap files trees)) of
  Left message -> Left (message ++ "; give changed schema modules distinct names (for example SchemaV1 and SchemaV2), with qualified imports for readability")
  Right tree -> Right tree

proposed :: Eff es (Either [Diagnostic] a) -> ExceptT PreviewRejection (Eff es) a
proposed = ExceptT . fmap (either (Left . ProposedCodeRejected) Right)

checked :: String -> Either String a -> ExceptT PreviewRejection (Eff es) a
checked code = either (reject code) pure

reject :: String -> String -> ExceptT PreviewRejection (Eff es) a
reject code = throwE . ProposedCodeRejected . pure . errorDiagnostic code
