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
import Kyyn.Domain.Path (RelativePath, scopePath, relativeName)
import Kyyn.Domain.Publication
import Kyyn.Domain.Workspace (EvolutionState(..))
import qualified Kyyn.Plumbing.Capability.Git as Git
import Kyyn.Porcelain.Capability.RootPublication (RootPublication(..))
import qualified Kyyn.Porcelain.Capability.EvolutionStore as EvolutionStore
import qualified Kyyn.Porcelain.Capability.RootStore as RootStore

runRootPublication
  :: (RootStore.RootStore :> es, EvolutionStore.EvolutionStore :> es, Git.Git :> es)
  => Eff (RootPublication : es) a -> Eff es a
runRootPublication = interpret $ \_ -> \case
  AcceptEvolution branch metadata candidate@(Candidate context@(EvolutionContext kb@(KnowledgeBase repository _)
      identity (Before expected _) _) _ root) -> fmap (either id id) . runExceptT $ do
    state <- material (EvolutionStore.readEvolutionState (EvolutionWorkspace kb identity))
    unless (state == Ready) (refuse (NotReady state))
    requireBranch repository branch
    observed <- material (Git.resolveRevision repository "HEAD")
    unless (observed == expected) (refuse (BaseMismatch expected (Just observed)))
    rootPath <- material (pure (mapPath (RootStore.rootLocation kb)))
    overlaps <- liftEff (Git.checkoutChanges repository expected [rootPath])
    unless (null overlaps) (refuse (OverlappingEdits overlaps))
    matches <- material (EvolutionStore.matchesCapturedInputs context)
    unless matches (refuse (WorkspaceChanged identity))
    rootFiles <- material (RootStore.exportRootFiles root)
    archive@(archiveLocation, _) <- material (EvolutionStore.exportAcceptedWorkspace candidate)
    archivePath <- case archiveLocation of
      Subtree path -> pure path
      WholeTree -> refuse (InvalidMaterial [errorDiagnostic "acceptance.archive-path" "Archive must occupy a subtree"])
    revision <- liftEff (Git.createCommit repository (GitTree [(Subtree rootPath, rootFiles), archive]) (Just expected) metadata)
    requireBranch repository branch
    update <- liftEff (Git.compareAndSwapRef repository branch (Just expected) revision)
    case update of
      RefUpdated -> do
        result <- liftEff (Git.synchronizeCheckout repository branch revision [rootPath, archivePath])
        pure (AcceptedCommit revision (syncOutcome repository revision [rootPath, archivePath] result))
      RefNotUpdated actual -> pure (NotAccepted (BaseMismatch expected actual))

requireBranch :: Git.Git :> es => Repository -> LocalBranch -> ExceptT AcceptanceResult (Eff es) ()
requireBranch repository selected = do
  actual <- liftEff (Git.checkedOutBranch repository)
  unless (actual == Just selected) (refuse (CheckoutMismatch selected actual))

syncOutcome :: Repository -> GitRevision -> [RelativePath] -> Either [Diagnostic] () -> WorkingTreeOutcome
syncOutcome (Repository scope) revision paths = either incomplete (const WorkingTreeUpdated)
  where
    incomplete diagnostics = WorkingTreeUpdateIncomplete (diagnostics ++
      [errorDiagnostic "acceptance.checkout-incomplete"
        ("Accepted at " ++ revisionName revision ++ ". Inspect git status first; this restores current HEAD " ++
         "and overwrites local edits to the root and this workspace. Inspect untracked files separately.\n" ++
         "git -C " ++ quote (scopePath scope) ++ " restore --source=HEAD --staged --worktree -- " ++
         unwords (map (quote . relativeName) paths))])
    quote value = "'" ++ concatMap (\c -> if c == '\'' then "'\\''" else [c]) value ++ "'"

refuse :: AcceptanceProblem -> ExceptT AcceptanceResult (Eff es) a
refuse = throwE . NotAccepted

material :: Eff es (Either [Diagnostic] a) -> ExceptT AcceptanceResult (Eff es) a
material action = ExceptT (either (Left . NotAccepted . InvalidMaterial) Right <$> action)

mapPath :: Either String a -> Either [Diagnostic] a
mapPath = either (Left . pure . errorDiagnostic "acceptance.path") Right

liftEff :: Eff es a -> ExceptT e (Eff es) a
liftEff action = ExceptT (Right <$> action)
