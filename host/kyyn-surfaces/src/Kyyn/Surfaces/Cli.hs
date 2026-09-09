module Kyyn.Surfaces.Cli
  ( Invocation(..), Selection(..), OutputMode(..), Command(..)
  , RootCommand(..), EvolutionCommand(..), cliInfo, parseArguments
  ) where

import Kyyn.Domain.Evolution (EvolutionId, EvolutionName(..), EvolutionFilter(..), evolutionId)
import Kyyn.Domain.Git (GitRevision, LocalBranch(..), gitRevision)
import Options.Applicative

data Invocation = Invocation
  { selection :: Selection
  , output :: OutputMode
  , command :: Command
  } deriving (Eq, Show)

data Selection = Selection
  { kb :: FilePath
  , branch :: Maybe LocalBranch
  , git :: Maybe FilePath
  , runtime :: Maybe FilePath
  } deriving (Eq, Show)

data OutputMode = Human | Json deriving (Eq, Show)

data Command = Root RootCommand | Evolution EvolutionCommand deriving (Eq, Show)
data RootCommand = ShowRoot | CheckRoot deriving (Eq, Show)

data EvolutionCommand
  = NewEvolution EvolutionName (Maybe GitRevision)
  | ListEvolutions EvolutionFilter
  | ShowEvolution EvolutionId
  | EvaluateEvolution EvolutionId
  | CheckEvolution EvolutionId
  | ReadyEvolution EvolutionId
  | DraftEvolution EvolutionId
  | AcceptEvolution EvolutionId
  | RecoverEvolution EvolutionId
  deriving (Eq, Show)

cliInfo :: ParserInfo Invocation
cliInfo = info (invocation <**> helper)
  (fullDesc <> progDesc "Inspect knowledge and prepare, check and accept evolutions")

parseArguments :: [String] -> ParserResult Invocation
parseArguments = execParserPure (prefs showHelpOnEmpty) cliInfo

invocation :: Parser Invocation
invocation = Invocation <$> selectionParser
  <*> flag Human Json (long "json" <> help "Write structured JSON results")
  <*> hsubparser
    (group "root" "Inspect and check the accepted root" (Root <$> rootParser)
    <> group "evolution" "Prepare and accept changes" (Evolution <$> evolutionParser))

selectionParser :: Parser Selection
selectionParser = Selection
  <$> strOption (long "kb" <> metavar "PATH" <> value "." <> showDefault
      <> help "KB directory (may be inside a larger Git repository)")
  <*> optional (LocalBranch <$> strOption (long "branch" <> metavar "NAME"
      <> help "Select a local branch (default: checked-out branch)"))
  <*> optional (strOption (long "git" <> metavar "EXECUTABLE"
      <> help "Git executable override (default: locate Git on PATH)"))
  <*> optional (strOption (long "runtime" <> metavar "DIRECTORY"
      <> help "Bundled runtime directory override"))

rootParser :: Parser RootCommand
rootParser = hsubparser
  (group "show" "Inspect the accepted root at the selected revision" (pure ShowRoot)
  <> group "check" "Check the accepted root, including required examples" (pure CheckRoot))

evolutionParser :: Parser EvolutionCommand
evolutionParser = hsubparser
  (group "new" "Create a draft workspace from the selected head or explicit base"
      (NewEvolution <$> (EvolutionName <$> argument nonempty (metavar "NAME"))
        <*> optional (option (eitherReader gitRevision)
          (long "before" <> metavar "REVISION" <> help "Full Before commit ID (default: selected head)")))
  <> group "list" "List evolution workspaces"
      (ListEvolutions <$> flag AllEvolutions ExcludeDrafts
        (long "exclude-drafts" <> help "Omit work-in-progress drafts"))
  <> group "show" "Inspect lifecycle state and the available evolution report" (ShowEvolution <$> identity)
  <> group "evaluate" "Execute the evolution and save its candidate" (EvaluateEvolution <$> identity)
  <> group "check" "Check the saved candidate without rerunning the evolution" (CheckEvolution <$> identity)
  <> group "ready" "Mark a workspace ready for acceptance" (ReadyEvolution <$> identity)
  <> group "draft" "Return a workspace to draft" (DraftEvolution <$> identity)
  <> group "accept" "Check and accept the saved candidate against its Before revision" (AcceptEvolution <$> identity)
  <> group "recover" "Repair the checkout after an accepted evolution" (RecoverEvolution <$> identity))

identity :: Parser EvolutionId
identity = argument (eitherReader evolutionId) (metavar "ID")

nonempty :: ReadM String
nonempty = eitherReader $ \name ->
  if null name then Left "name must not be empty" else Right name

group :: String -> String -> Parser a -> Mod CommandFields a
group name description parser = Options.Applicative.command name
  (info (parser <**> helper) (progDesc description))
