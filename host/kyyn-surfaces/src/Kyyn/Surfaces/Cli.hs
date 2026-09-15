module Kyyn.Surfaces.Cli
  ( Invocation(..), Selection(..), OutputMode(..), Command(..)
  , KbCommand(..), RootCommand(..), EvolutionCommand(..), cliInfo, cliPrefs, parseArguments, progressMessage
  , GuestCommand(..), PluginCommand(..), ConnectorCommand(..), EvidenceCommand(..), ToolCommand(..)
  ) where

import Kyyn.Domain.Evolution (EvolutionId, EvolutionName(..), EvolutionFilter(..), evolutionId, evolutionIdName)
import Kyyn.Domain.Git (GitRevision, gitRevision)
import Kyyn.Domain.Plugin (PluginName, ConnectorName(..), MethodName, methodName, pluginName, connectorName, pluginNameText)
import Kyyn.Domain.Evidence (FetchId(..))
import Data.Coerce (coerce)
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

data Command = Kb KbCommand | Root RootCommand | Evolution EvolutionCommand | Guest (Maybe EvolutionId) GuestCommand | Plugin PluginCommand | Evidence EvidenceCommand deriving (Eq, Show)
data PluginCommand = InstallPlugin EvolutionId String (Maybe FilePath) | Connector ConnectorCommand deriving (Eq, Show)
data ConnectorCommand
  = ListConnectors PluginName (Maybe EvolutionId)
  | ShowConnectorSchema PluginName (Maybe EvolutionId)
  | ListConnectorMethods PluginName ConnectorName (Maybe EvolutionId)
  | ShowConnectorMethod PluginName ConnectorName MethodName (Maybe EvolutionId)
  | ExecuteConnectorMethod PluginName ConnectorName MethodName String
  deriving (Eq, Show)
data EvidenceCommand
  = FetchConnector PluginName ConnectorName
  | ListFetchHistory PluginName ConnectorName
  | ListEvidenceChanges PluginName ConnectorName (Maybe FetchId)
  | ClearEvidence PluginName ConnectorName
  deriving (Eq, Show)
data GuestCommand = ListGuestModules | ShowGuestModule String | ShowGuestSymbol String deriving (Eq, Show)
data KbCommand = InitKb deriving (Eq, Show)
data RootCommand = ShowRoot | CheckRoot | RootTool ToolCommand deriving (Eq, Show)
data ToolCommand = ListTools (Maybe EvolutionId) | ShowTool MethodName (Maybe EvolutionId)
  | ExecuteTool MethodName String deriving (Eq, Show)

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
  Plugin (InstallPlugin selectedId _ _) -> Just ("Installing plugin source into evolution " ++ evolutionIdName selectedId ++ "...")
  Evidence (FetchConnector plugin connector) -> Just
    ("Checking the root and fetching " ++ pluginNameText plugin ++ "/" ++ coerce connector ++ "...")
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
    <> group "guest" "Explore the guest SDK and workspace bindings" guestParser
    <> group "plugin" "Manage plugins and connector configuration" (Plugin <$> hsubparser
      (group "install" "Copy a committed plugin package into an evolution target"
        (InstallPlugin <$> option (eitherReader evolutionId) (long "evolution" <> metavar "ID" <> help "Evolution to receive the plugin")
          <*> strOption (long "from" <> metavar "SOURCE" <> help "Local Git checkout directory or Git URL")
          <*> optional (strOption (long "path" <> metavar "SUBDIRECTORY" <> help "Package directory within the selected source")))
       <> group "connector" "Inspect configured connectors" (Connector <$> connectorParser)))
    <> group "evidence" "Fetch and inspect captured evidence history" (Evidence <$> evidenceParser)
    <> group "evolution" "Prepare and accept changes" (Evolution <$> evolutionParser))

connectorParser :: Parser ConnectorCommand
connectorParser = hsubparser
  (group "list" "List a plugin's configured instances" (ListConnectors <$> plugin <*> evolution)
  <> group "schema" "Discover connector configuration schemas" (hsubparser
      (group "show" "Print the derived Dhall type for a plugin's configuration file" (ShowConnectorSchema <$> pluginArgument <*> evolution)))
  <> group "method" "Discover and invoke captured-evidence methods" (hsubparser
      (group "list" "List a connector instance's methods" (ListConnectorMethods <$> plugin <*> instanceName <*> evolution)
      <> group "show" "Show a method's description and Dhall input/result types" (ShowConnectorMethod <$> plugin <*> instanceName <*> method <*> evolution)
      <> group "execute" "Invoke a method over the latest fetched evidence"
        (ExecuteConnectorMethod <$> plugin <*> instanceName <*> method
          <*> strOption (long "input" <> metavar "DHALL" <> help "Input value as a hermetic Dhall expression")))))
  where
    plugin = pluginArgument
    instanceName = argument (eitherReader connectorName) (metavar "INSTANCE")
    method = argument (eitherReader methodName) (metavar "METHOD")
    evolution = optional (option (eitherReader evolutionId) (long "evolution" <> metavar "ID" <> help "Inspect an evolution target instead of the accepted root"))

pluginArgument :: Parser PluginName
pluginArgument = argument (eitherReader pluginName) (metavar "PLUGIN")

evidenceParser :: Parser EvidenceCommand
evidenceParser = hsubparser
  (group "fetch" "Fetch evidence from an accepted connector instance" (FetchConnector <$> plugin <*> instanceName)
  <> group "history" "Inspect retained fetch history" (hsubparser
      (group "list" "List fetches without evidence payloads" (ListFetchHistory <$> plugin <*> instanceName)))
  <> group "change" "Inspect evidence changes" (hsubparser
      (group "list" "List changes through the latest fetch" (ListEvidenceChanges <$> plugin <*> instanceName
        <*> optional (option fetchId (long "since" <> metavar "FETCH" <> help "Exclusive previous fetch")))))
  <> group "clear" "Clear one connector instance's evidence cache" (ClearEvidence <$> plugin <*> instanceName))
  where
    plugin = pluginArgument
    instanceName = argument (eitherReader connectorName) (metavar "INSTANCE")
    fetchId = eitherReader (\identifier -> if null identifier then Left "Fetch ID must not be empty" else Right (FetchId identifier))

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
  <> group "check" "Check the accepted root, including required examples" (pure CheckRoot)
  <> group "tool" "Discover and invoke KB-authored investigation helpers" (RootTool <$> hsubparser
    (group "list" "List registered KB tools" (ListTools <$> workspace)
    <> group "show" "Show a tool's description and Dhall types" (ShowTool <$> name <*> workspace)
    <> group "execute" "Execute an accepted KB tool" (ExecuteTool <$> name
      <*> strOption (long "input" <> metavar "DHALL" <> help "Input value as a hermetic Dhall expression")))))
  where
    name = argument (eitherReader methodName) (metavar "TOOL")
    workspace = optional (option (eitherReader evolutionId) (long "evolution" <> metavar "ID" <> help "Inspect an evolution target"))

guestParser :: Parser Command
guestParser = hsubparser
  (group "module" "Explore public guest modules" (hsubparser
    (group "list" "List public modules" (scoped (pure ListGuestModules))
    <> group "show" "Show a module's exported types and functions"
      (scoped (ShowGuestModule <$> argument nonempty (metavar "MODULE")))))
  <> group "symbol" "Inspect an exported type or function" (hsubparser
    (group "show" "Show an exported symbol's signature and origin"
      (scoped (ShowGuestSymbol <$> argument nonempty (metavar "MODULE.SYMBOL"))))))
  where
    scoped parser = flip Guest <$> parser <*> optional (option (eitherReader evolutionId)
      (long "evolution" <> metavar "ID" <> help "Include the selected evolution workspace's generated bindings"))

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
