module Kyyn.Surfaces.Cli
  ( Invocation(..), Selection(..), OutputMode(..), Command(..)
  , KbCommand(..), RootCommand(..), EvolutionCommand(..), cliInfo, cliPrefs, parseArguments, progressMessage
  , GuestCommand(..)
  ) where

import Kyyn.Domain.Evolution (EvolutionId, EvolutionName(..), EvolutionFilter(..), evolutionId, evolutionIdName)
import Kyyn.Domain.Git (GitRevision, gitRevision)
import Options.Applicative

data Invocation = Invocation
  { selection :: Selection
  , output :: OutputMode
  , command :: Command
  } deriving (Eq, Show)

data Selection = Selection
  { kb :: FilePath
  , git :: Maybe FilePath
  , runtime :: Maybe FilePath
  } deriving (Eq, Show)

data OutputMode = Human | Json deriving (Eq, Show)

data Command = Kb KbCommand | Root RootCommand | Evolution EvolutionCommand | Guest GuestCommand deriving (Eq, Show)
data GuestCommand = ListGuestModules | ShowGuestModule String | ShowGuestSymbol String deriving (Eq, Show)
data KbCommand = InitKb deriving (Eq, Show)
data RootCommand = ShowRoot | CheckRoot deriving (Eq, Show)

data EvolutionCommand
  = NewEvolution EvolutionName (Maybe GitRevision)
  | ListEvolutions EvolutionFilter
  | ShowEvolution EvolutionId
  | CheckEvolution EvolutionId
  | ReadyEvolution EvolutionId
  | DraftEvolution EvolutionId
  | AcceptEvolution EvolutionId
  | RecoverEvolution EvolutionId
  deriving (Eq, Show)

cliInfo :: ParserInfo Invocation
cliInfo = info (invocation <**> helper)
  (fullDesc <> failureCode 2 <> progDesc "Inspect knowledge and prepare, check and accept evolutions")

parseArguments :: [String] -> ParserResult Invocation
parseArguments = execParserPure cliPrefs cliInfo

cliPrefs :: ParserPrefs
cliPrefs = prefs (showHelpOnEmpty <> showHelpOnError)

progressMessage :: Command -> Maybe String
progressMessage request = case request of
  Kb InitKb -> Just "Checking and initializing the knowledge base..."
  Root ShowRoot -> Just "Checking and reading the root..."
  Root CheckRoot -> Just "Checking the root..."
  Evolution (NewEvolution _ _) -> Just "Preparing an evolution workspace..."
  Evolution (CheckEvolution selectedId) -> Just ("Evaluating and checking evolution " ++ evolutionIdName selectedId ++ "...")
  Evolution (AcceptEvolution selectedId) -> Just ("Checking and accepting evolution " ++ evolutionIdName selectedId ++ "...")
  _ -> Nothing

invocation :: Parser Invocation
invocation = Invocation <$> selectionParser
  <*> flag Human Json (long "json" <> help "Write structured JSON results")
  <*> hsubparser
    (group "kb" "Create a knowledge base" (hsubparser
      (group "init" "Initialize an empty knowledge base and commit its validated root" (pure (Kb InitKb))))
    <> group "root" "Inspect and check the accepted root" (Root <$> rootParser)
    <> group "guest" "Explore the installed guest SDK" (Guest <$> guestParser)
    <> group "evolution" "Prepare and accept changes" (Evolution <$> evolutionParser))

selectionParser :: Parser Selection
selectionParser = Selection
  <$> strOption (long "kb" <> metavar "PATH" <> value "." <> showDefault
      <> help "KB directory (may be inside a larger Git repository)")
  <*> optional (strOption (long "git" <> metavar "EXECUTABLE"
      <> help "Git executable override (default: locate Git on PATH)"))
  <*> optional (strOption (long "runtime" <> metavar "DIRECTORY"
      <> help "Bundled runtime directory override"))

rootParser :: Parser RootCommand
rootParser = hsubparser
  (group "show" "Inspect the accepted root at the selected revision" (pure ShowRoot)
  <> group "check" "Check the accepted root, including required examples" (pure CheckRoot))

guestParser :: Parser GuestCommand
guestParser = hsubparser
  (group "module" "Explore public guest modules" (hsubparser
    (group "list" "List public modules" (pure ListGuestModules)
    <> group "show" "Show a module's exported types and functions"
      (ShowGuestModule <$> argument nonempty (metavar "MODULE"))))
  <> group "symbol" "Inspect an exported type or function" (hsubparser
    (group "show" "Show an exported symbol's signature and origin"
      (ShowGuestSymbol <$> argument nonempty (metavar "MODULE.SYMBOL")))))

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
  <> group "check" "Evaluate the current workspace, save its candidate and validate it" (CheckEvolution <$> identity)
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
