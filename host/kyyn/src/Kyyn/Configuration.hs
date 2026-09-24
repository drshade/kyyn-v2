{-# LANGUAGE DataKinds #-}
module Kyyn.Configuration
  ( Host(..), SelectedKb(..), configure, runtimeDirectory, selectKnowledgeBase, commitMetadata, runGitIO ) where

import Control.Monad.Trans.Except (ExceptT(..), runExceptT, throwE)
import Control.Monad.IO.Class (liftIO)
import Data.Time.Clock.POSIX (getPOSIXTime)
import Effectful (Eff, IOE, runEff)
import Kyyn.Domain.Diagnostic (errorDiagnostic)
import Kyyn.Composition.Timings (Timings, newTimings)
import Kyyn.Build (buildRevision)
import Kyyn.MicroHs.Interpreter.InspectionCache (InspectionCache(..))
import Kyyn.Domain.Git
import Kyyn.Domain.KnowledgeBase (KnowledgeBase(..))
import Kyyn.Domain.Path
import Kyyn.Domain.Failure (OperationalFailure)
import Kyyn.Plumbing.Capability.Failure (Failure)
import qualified Kyyn.Plumbing.Capability.Git as Git
import Kyyn.Plumbing.Capability.ProcessExecution (ProcessExecution)
import Kyyn.Plumbing.Interpreter.Failure (runFailure)
import Kyyn.Plumbing.Interpreter.Git (runGit)
import Kyyn.Plumbing.Interpreter.ProcessExecution (runProcessExecutionIO)
import qualified Kyyn.Surfaces.Cli as Cli
import Kyyn.Surfaces.Result (Response, refusal, operationalFailure)
import System.Directory (canonicalizePath, doesDirectoryExist, doesFileExist, findExecutable, getTemporaryDirectory)
import System.Environment (getExecutablePath, lookupEnv)
import System.FilePath ((</>), takeDirectory)

data Host = Host
  { gitExecutable :: FilePath, gitConfigurationEnvironment :: [(String,String)]
  , temporary :: DirectoryScope, runtime :: FilePath, compilationCache :: Maybe DirectoryScope
  , inspectionCache :: Maybe InspectionCache, timings :: Maybe Timings }
data SelectedKb = SelectedKb
  { knowledgeBase :: KnowledgeBase, revision :: GitRevision, branch :: Maybe LocalBranch }

configure :: Cli.Selection -> IO (Either Response (Host, DirectoryScope))
configure (Cli.Selection path gitOverride runtimeOverride) = runExceptT $ do
  kbPath <- liftIO (canonicalizePath path)
  scope <- either (invalid "kb.path") pure (directoryScope kbPath)
  executable <- liftIO (findExecutable (maybe "git" id gitOverride))
    >>= maybe (invalid "setup.git" "Git was not found; install Git or supply --git EXECUTABLE") pure
  git <- liftIO (canonicalizePath executable)
  temp <- liftIO getTemporaryDirectory >>= either (invalid "setup.temporary") pure . directoryScope
  runtime <- liftIO (runtimeDirectory runtimeOverride)
  hasKb <- liftIO (doesFileExist (kbPath </> "root/kb.dhall"))
  cache <- if hasKb then Just <$> either (invalid "kb.path") pure (directoryScope (kbPath </> ".kyyn/compiled")) else pure Nothing
  inspection <- case (hasKb,buildRevision) of
    (True,Just revision) -> Just . InspectionCache revision <$> either (invalid "kb.path") pure (directoryScope (kbPath </> ".kyyn/inspected"))
    _ -> pure Nothing
  let keys = ["HOME", "XDG_CONFIG_HOME"]
  values <- liftIO (mapM lookupEnv keys)
  timings <- liftIO newTimings
  pure (Host git [(key,value) | (key,Just value) <- zip keys values] temp runtime cache inspection timings, scope)
  where invalid code = throwE . refusal . pure . errorDiagnostic code

runtimeDirectory :: Maybe FilePath -> IO FilePath
runtimeDirectory override = do
  installed <- getExecutablePath >>= canonicalizePath
  canonicalizePath (maybe (takeDirectory (takeDirectory installed) </> "lib/kyyn") id override)

runGitIO :: Host -> Eff '[Git.Git, ProcessExecution, Failure, IOE] a -> IO (Either OperationalFailure a)
runGitIO (Host executable environment _ _ _ _ _) = runEff . runFailure . runProcessExecutionIO . runGit executable environment

selectKnowledgeBase :: Host -> DirectoryScope -> IO (Either Response SelectedKb)
selectKnowledgeBase host scope = do
  exists <- doesDirectoryExist (scopePath scope)
  if exists then selectExistingKnowledgeBase host scope
  else pure (Left (refusal [errorDiagnostic "kb.directory" ("No KB directory exists at " ++ scopePath scope)]))

selectExistingKnowledgeBase :: Host -> DirectoryScope -> IO (Either Response SelectedKb)
selectExistingKnowledgeBase host scope = do
  result <- runGitIO host $ runExceptT $ do
    (repository,prefix) <- ExceptT (Git.discoverRepository scope)
    revision <- ExceptT (Git.resolveRevision repository "HEAD")
    path <- either (throwE . pure . errorDiagnostic "kb.path") pure $ relativePath
      ((case prefix of WholeTree -> ""; Subtree p -> relativeName p ++ "/") ++ "root/kb.dhall")
    manifest <- ExceptT (Git.readFileAt repository revision path)
    case manifest of
      Nothing -> throwE [errorDiagnostic "kb.not-found"
        ("No accepted root/kb.dhall at " ++ scopePath scope ++ "; select the KB directory with --kb PATH")]
      Just _ -> do
        branch <- ExceptT (Right <$> Git.checkedOutBranch repository)
        pure (SelectedKb (KnowledgeBase repository prefix) revision branch)
  pure (either (Left . operationalFailure) (either (Left . refusal) Right) result)

commitMetadata :: Host -> Repository -> String -> IO (Either Response CommitMetadata)
commitMetadata host repository message = do
  result <- runGitIO host (Git.readUserIdentity repository)
  case result of
    Left failure -> pure (Left (operationalFailure failure))
    Right (Left diagnostics) -> pure (Left (refusal diagnostics))
    Right (Right (GitUser name email)) -> do
      timestamp <- getPOSIXTime
      let identity = CommitIdentity name email (show (floor timestamp :: Integer) ++ " +0000")
      pure (Right (CommitMetadata identity identity message))
