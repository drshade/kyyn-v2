{-# LANGUAGE GADTs #-}
module Kyyn.Porcelain.Interpreter.EvolutionExecution (runEvolutionExecution) where

import Control.Monad (unless)
import Control.Monad.Trans.Except (ExceptT(..), runExceptT, throwE)
import Data.Aeson (encode)
import qualified Data.ByteString.Lazy as Bytes
import Effectful (Eff, (:>))
import Effectful.Dispatch.Dynamic (interpret)
import Kyyn.Domain.Diagnostic (Diagnostic, errorDiagnostic)
import Kyyn.Domain.Evolution
import Kyyn.Domain.FileTree (FileTree, files, fileTree)
import Kyyn.Domain.Root (Root(..), SourceRoot(..), RootDefinition(..), CheckedValue(..))
import Kyyn.Domain.Workspace (WorkspaceSnapshot(..))
import Kyyn.Domain.Failure (OperationalFailure(..), ProcessDiagnostic(..), ProcessOperation(..))
import Kyyn.Plumbing.Capability.Failure (Failure, raiseFailure)
import Kyyn.Plumbing.Capability.GuestCompilation (GuestCompilation, compileGuest, executeCompiledEntry)
import Kyyn.Plumbing.Protocol.Evolution (evolutionSources, decodeEvolutionReply, mergeEvolutionSources)
import Kyyn.Porcelain.Capability.EvolutionExecution (EvolutionExecution(..))
import Kyyn.Porcelain.Capability.EvolutionReport (checkEvolutionReport)
import Kyyn.Porcelain.Capability.RootStore (RootStore, readRootDefinition, loadRootValueForChecking)

runEvolutionExecution
  :: (RootStore :> es,
      GuestCompilation :> es, Failure :> es)
  => FileTree -> Eff (EvolutionExecution : es) a -> Eff es a
runEvolutionExecution sdk = interpret $ \_ (EvaluateEvolution captured@(CapturedEvolution
    (EvolutionContext _ _ (Before _ expected)
      (WorkspaceSnapshot _ before target change _)) source@(Root actual _ acceptedCode) closure
      (SourceRoot after preparedCode (RootDefinition _ _ _ _ targetSources) _))) -> runExceptT $ do
  unless (actual == expected) (reject "evolution.before-contract" "Captured input does not match Before's contract")
  RootDefinition _ _ _ _ acceptedSources <- proposed (readRootDefinition acceptedCode)
  unless (before == acceptedSources) (reject "evolution.before-source" "Captured input does not match Before's source")
  unless (target == preparedCode) (reject "evolution.after-source" "Prepared After does not match the captured target")
  CheckedValue _ input <- proposed (loadRootValueForChecking source)
  old <- checked "evolution.before-closure" (fileTree [(p,b) | (p,b) <- files before, p `elem` closure])
  combined <- checked "evolution.source-collision" (mergeEvolutionSources [old,targetSources,change,sdk])
  prepared <- checked "evolution.prepare" (evolutionSources expected after combined)
  compiled <- proposed (compileGuest prepared)
  output <- ExceptT (Right <$> executeCompiledEntry "Evolution.evolution" compiled (Bytes.toStrict (encode input)))
  reply <- case decodeEvolutionReply output of
    Left message -> ExceptT (raiseFailure (RuntimeUnavailable (ProcessDiagnostic ReadOutput
      ("Evolution.evolution: " ++ message))))
    Right (Left failure) -> throwE (EvolutionRejected failure)
    Right (Right result) -> pure result
  result <- proposed (checkEvolutionReport expected input after reply)
  let (value,report) = result
  pure (EvaluatedEvolution captured (After after) value report)

proposed :: Eff es (Either [Diagnostic] a) -> ExceptT PreviewRejection (Eff es) a
proposed = ExceptT . fmap (either (Left . ProposedCodeRejected) Right)

checked :: String -> Either String a -> ExceptT PreviewRejection (Eff es) a
checked code = either (reject code) pure

reject :: String -> String -> ExceptT PreviewRejection (Eff es) a
reject code = throwE . ProposedCodeRejected . pure . errorDiagnostic code
