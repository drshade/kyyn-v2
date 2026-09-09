{-# LANGUAGE DataKinds #-}
module Kyyn.Configuration
  ( Host(..), SelectedKb(..), configure, selectKnowledgeBase, commitMetadata, runGitIO ) where

import Control.Applicative ((<|>))
import Control.Monad.Trans.Except (ExceptT(..), runExceptT, throwE)
import Control.Monad.IO.Class (liftIO)
import Data.Time.Clock.POSIX (getPOSIXTime)
import Effectful (Eff, IOE, runEff)
import Kyyn.Domain.Diagnostic (errorDiagnostic)
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
import System.Directory (canonicalizePath, doesDirectoryExist, findExecutable, getTemporaryDirectory)
import System.Environment (getExecutablePath, lookupEnv)
import System.FilePath ((</>), takeDirectory)

data Host = Host
  { gitExecutable :: FilePath, temporary :: DirectoryScope, runtime :: FilePath }
data SelectedKb = SelectedKb
  { knowledgeBase :: KnowledgeBase, revision :: GitRevision, branch :: Maybe LocalBranch }

configure :: Cli.Selection -> IO (Either Response (Host, DirectoryScope))
configure (Cli.Selection path gitOverride runtimeOverride) = runExceptT $ do
  kbPath <- liftIO (canonicalizePath path)
  exists <- liftIO (doesDirectoryExist kbPath)
  if exists then pure () else invalid "kb.directory" ("No KB directory exists at " ++ kbPath)
  scope <- either (invalid "kb.path") pure (directoryScope kbPath)
  executable <- liftIO (findExecutable (maybe "git" id gitOverride))
    >>= maybe (invalid "setup.git" "Git was not found; install Git or supply --git EXECUTABLE") pure
  git <- liftIO (canonicalizePath executable)
  temp <- liftIO getTemporaryDirectory >>= either (invalid "setup.temporary") pure . directoryScope
  installed <- liftIO getExecutablePath
  runtime <- liftIO (canonicalizePath (maybe (takeDirectory (takeDirectory installed) </> "lib/kyyn") id runtimeOverride))
  pure (Host git temp runtime, scope)
  where invalid code = throwE . refusal . pure . errorDiagnostic code

runGitIO :: Host -> Eff '[Git.Git, ProcessExecution, Failure, IOE] a -> IO (Either OperationalFailure a)
runGitIO (Host executable _ _) = runEff . runFailure . runProcessExecutionIO . runGit executable

selectKnowledgeBase :: Host -> DirectoryScope -> IO (Either Response SelectedKb)
selectKnowledgeBase host scope = do
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

commitMetadata :: String -> IO (Either Response CommitMetadata)
commitMetadata message = do
  authorName <- lookupEnv "GIT_AUTHOR_NAME"
  authorEmail <- lookupEnv "GIT_AUTHOR_EMAIL"
  committerName <- lookupEnv "GIT_COMMITTER_NAME"
  committerEmail <- lookupEnv "GIT_COMMITTER_EMAIL"
  timestamp <- getPOSIXTime
  let date = show (floor timestamp :: Integer) ++ " +0000"
      present = maybe False (not . null)
  pure $ case (authorName,authorEmail,committerName <|> authorName,committerEmail <|> authorEmail) of
    (Just name,Just email,Just cName,Just cEmail)
      | all present [Just name,Just email,Just cName,Just cEmail] ->
        Right (CommitMetadata (CommitIdentity name email date) (CommitIdentity cName cEmail date) message)
    _ -> Left (refusal [errorDiagnostic "acceptance.identity"
      "Set GIT_AUTHOR_NAME and GIT_AUTHOR_EMAIL before accepting. GIT_COMMITTER_NAME and GIT_COMMITTER_EMAIL optionally override the committer."])
