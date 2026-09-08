{-# LANGUAGE GADTs, LambdaCase #-}
module Kyyn.Porcelain.Interpreter.RootPublication (runRootPublication) where

import Control.Monad (unless)
import Control.Monad.Trans.Except (ExceptT(..), runExceptT, throwE)
import Effectful (Eff, (:>))
import Effectful.Dispatch.Dynamic (interpret)
import Kyyn.Domain.Diagnostic (Diagnostic, errorDiagnostic)
import Kyyn.Domain.Evolution
import Kyyn.Domain.Git
import Kyyn.Domain.KnowledgeBase (KnowledgeBase(..))
import Kyyn.Domain.Publication
import Kyyn.Domain.Workspace (EvolutionState(..))
import qualified Kyyn.Plumbing.Capability.Git as Git
import Kyyn.Porcelain.Capability.RootPublication (RootPublication(..), alreadyAccepted)
import qualified Kyyn.Porcelain.Capability.EvolutionStore as EvolutionStore
import qualified Kyyn.Porcelain.Capability.RootStore as RootStore

runRootPublication
  :: (RootStore.RootStore :> es, EvolutionStore.EvolutionStore :> es, Git.Git :> es)
  => Eff (RootPublication : es) a -> Eff es a
runRootPublication = interpret $ \_ -> \case
  FindAcceptanceOnBranch branch (EvolutionWorkspace kb@(KnowledgeBase repository _) identity) -> runExceptT $ do
    headRevision <- ExceptT (branchHead repository branch)
    ExceptT (EvolutionStore.findAcceptance kb identity headRevision)
  RecoverAcceptedEvolution branch location@(EvolutionWorkspace kb@(KnowledgeBase repository _) identity) -> runExceptT $ do
    branchNow <- liftEff (Git.checkedOutBranch repository)
    unless (branchNow == Just branch) (throwE [errorDiagnostic "acceptance.checkout-mismatch"
      "Check out the selected branch before synchronizing accepted files"])
    headRevision <- ExceptT (Git.resolveRevision repository "HEAD")
    accepted <- ExceptT (EvolutionStore.findAcceptance kb identity headRevision)
    traverse (\revision -> do
      root <- pathResult (RootStore.rootLocation kb)
      archive <- pathResult (EvolutionStore.workspaceLocation location)
      let paths = [root, archive]
      changes <- liftEff (Git.checkoutChanges repository headRevision paths)
      result <- if null changes then pure WorkingTreeUpdated
        else syncOutcome <$> liftEff (Git.synchronizeCheckout repository branch headRevision paths)
      pure (CheckoutRecovery revision headRevision result)) accepted
  AcceptEvolution branch metadata candidate@(Candidate context@(EvolutionContext kb@(KnowledgeBase repository _)
      identity (Before expected _) _) _ root) -> fmap (either id id) . runExceptT $ do
    selected <- material (branchHead repository branch)
    accepted <- material (EvolutionStore.findAcceptance kb identity selected)
    case accepted of
      Just revision -> throwE (alreadyAccepted revision)
      Nothing -> pure ()
    requireBranch repository branch
    observed <- material (Git.resolveRevision repository "HEAD")
    unless (observed == expected) (refuse (BaseMismatch expected (Just observed)))
    rootPath <- material (pure (mapPath (RootStore.rootLocation kb)))
    overlaps <- liftEff (Git.checkoutChanges repository expected [rootPath])
    unless (null overlaps) (refuse (OverlappingEdits overlaps))
    state <- material (EvolutionStore.readEvolutionState (EvolutionWorkspace kb identity))
    unless (state == Ready) (refuse (NotReady state))
    matches <- material (EvolutionStore.matchesCapturedInputs context)
    unless matches (refuse (WorkspaceChanged identity))
    rootFiles <- material (RootStore.exportRootFiles root)
    archive@(archiveLocation, _) <- material (EvolutionStore.exportAcceptedWorkspace candidate)
    archivePath <- case archiveLocation of
      Subtree path -> pure path
      WholeTree -> refuse (InvalidMaterial [errorDiagnostic "acceptance.archive-path" "Archive must occupy a subtree"])
    revision <- liftEff (Git.createCommit repository (GitTree [(Subtree rootPath, rootFiles), archive]) expected metadata)
    requireBranch repository branch
    update <- liftEff (Git.compareAndSwapRef repository branch expected revision)
    case update of
      RefUpdated -> do
        result <- liftEff (Git.synchronizeCheckout repository branch revision [rootPath, archivePath])
        pure (AcceptedCommit revision (syncOutcome result))
      RefNotUpdated actual -> do
        acceptedNow <- case actual of
          Nothing -> pure Nothing
          Just current -> material (EvolutionStore.findAcceptance kb identity current)
        pure $ maybe (NotAccepted (BaseMismatch expected actual)) alreadyAccepted acceptedNow

branchHead :: Git.Git :> es => Repository -> LocalBranch -> Eff es (Either [Diagnostic] GitRevision)
branchHead repository (LocalBranch branch) = Git.resolveRevision repository ("refs/heads/" ++ branch)

requireBranch :: Git.Git :> es => Repository -> LocalBranch -> ExceptT AcceptanceResult (Eff es) ()
requireBranch repository selected = do
  actual <- liftEff (Git.checkedOutBranch repository)
  unless (actual == Just selected) (refuse (CheckoutMismatch selected actual))

syncOutcome :: Either [Diagnostic] () -> WorkingTreeOutcome
syncOutcome = either WorkingTreeUpdateIncomplete (const WorkingTreeUpdated)

refuse :: AcceptanceProblem -> ExceptT AcceptanceResult (Eff es) a
refuse = throwE . NotAccepted

material :: Eff es (Either [Diagnostic] a) -> ExceptT AcceptanceResult (Eff es) a
material action = ExceptT (either (Left . NotAccepted . InvalidMaterial) Right <$> action)

mapPath :: Either String a -> Either [Diagnostic] a
mapPath = either (Left . pure . errorDiagnostic "acceptance.path") Right

pathResult :: Either String a -> ExceptT [Diagnostic] (Eff es) a
pathResult = ExceptT . pure . mapPath

liftEff :: Eff es a -> ExceptT e (Eff es) a
liftEff action = ExceptT (Right <$> action)
