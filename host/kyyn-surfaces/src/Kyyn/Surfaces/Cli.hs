module Kyyn.Surfaces.Cli
  ( Invocation(..), Selection(..), OutputMode(..), Command(..)
  , KbCommand(..), RootCommand(..), EvolutionCommand(..), cliInfo, cliPrefs, parseArguments, progressMessage
  , GuestCommand(..), PluginCommand(..), ConnectorCommand(..), EvidenceCommand(..), ToolCommand(..), RecipeCommand(..)
  , SecretCommand(..), SecretArgument(..)
  , TapCommand(..), GuideSelection(..)
  , SchemaCommand(..), CollectionCommand(..), FactCommand(..)
  ) where

import Kyyn.Domain.Evolution (EvolutionId, EvolutionName(..), EvolutionFilter(..), evolutionId, evolutionIdName)
import Kyyn.Domain.Git (GitRevision, gitRevision, GitUrl, gitUrl)
import Kyyn.Domain.Tap (TapName, tapName, qualifiedPlugin)
import Kyyn.Domain.Plugin (PluginName, ConnectorName(..), MethodName, methodName, pluginName, connectorName, pluginNameText)
import Kyyn.Domain.Evidence (FetchId(..), SyncMode(..))
import Kyyn.Domain.Curation (RecipeId, recipeId)
import Kyyn.Domain.Recipe (DescriptionFormat(..))
import Data.Coerce (coerce)
import Kyyn.Domain.Secret (SecretName, secretName)
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

data Command = Kb KbCommand | Root RootCommand | Evolution EvolutionCommand | Guest (Maybe EvolutionId) GuestCommand | Plugin PluginCommand | Tap TapCommand | Evidence EvidenceCommand | Secret SecretCommand deriving (Eq, Show)
data SecretCommand = SetSecret SecretName (Maybe SecretArgument) | ListSecrets | ShowSecret SecretName | RemoveSecret SecretName deriving (Eq, Show)
newtype SecretArgument = SecretArgument String deriving Eq
instance Show SecretArgument where show _ = "<secret>"
data PluginCommand = InstallPlugin EvolutionId String (Maybe FilePath)
  | InstallAvailablePlugin EvolutionId TapName PluginName
  | SearchPlugins String
  | ListPlugins (Maybe EvolutionId)
  | ShowPlugin PluginName (Maybe EvolutionId)
  | ReadPluginGuide GuideSelection (Maybe EvolutionId)
  | Connector ConnectorCommand deriving (Eq, Show)
data GuideSelection = InstalledGuide PluginName | AvailableGuide TapName PluginName deriving (Eq, Show)
data TapCommand = ListTaps | AddTap TapName GitUrl | RemoveTap TapName | UpdateTaps (Maybe TapName) deriving (Eq, Show)
data ConnectorCommand
  = ListConnectors PluginName (Maybe EvolutionId)
  | ShowConnector PluginName ConnectorName (Maybe EvolutionId)
  | LoginConnector PluginName ConnectorName
  | ShowConnectorSchema PluginName (Maybe EvolutionId)
  | ListConnectorMethods PluginName ConnectorName (Maybe EvolutionId)
  | ShowConnectorMethod PluginName ConnectorName MethodName (Maybe EvolutionId)
  | ExecuteConnectorMethod PluginName ConnectorName MethodName String
  deriving (Eq, Show)
data EvidenceCommand
  = FetchConnector PluginName ConnectorName (Maybe String) SyncMode
  | ListCurrentEvidence PluginName ConnectorName
  | ListFetchHistory PluginName ConnectorName
  | ListEvidenceChanges PluginName ConnectorName (Maybe FetchId)
  | ClearEvidence PluginName ConnectorName
  deriving (Eq, Show)
data GuestCommand = ListGuestModules | ShowGuestModule String | ShowGuestSymbol String deriving (Eq, Show)
data KbCommand = InitKb deriving (Eq, Show)
data RootCommand = ShowRoot | CheckRoot | RootTool ToolCommand | RootRecipe RecipeCommand
  | RootSchema SchemaCommand | RootCollection CollectionCommand | RootFact FactCommand deriving (Eq, Show)
data SchemaCommand = ListSchemas (Maybe EvolutionId) | ShowSchema String (Maybe EvolutionId) deriving (Eq, Show)
data CollectionCommand = ListCollections (Maybe EvolutionId) | ShowCollection String (Maybe EvolutionId) deriving (Eq, Show)
data FactCommand = ListFacts String | ShowFact String String deriving (Eq, Show)
data RecipeCommand = ListRecipes | ShowRecipe RecipeId | ListPendingEvidence RecipeId PluginName ConnectorName
  | DescribeRecipe RecipeId DescriptionFormat
  | RunRecipe RecipeId [(PluginName,ConnectorName)] deriving (Eq, Show)
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
  Evidence (FetchConnector plugin connector _ _) -> Just
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
    <> group "tap" "Manage KB-local plugin catalogues" (Tap <$> tapParser)
    <> group "guest" "Explore the guest SDK, KB modules and generated bindings" guestParser
    <> group "plugin" "Manage plugins and connector configuration" (Plugin <$> hsubparser
      (group "install" "Install or replace a plugin from source HEAD in an evolution target"
        (pluginInstallParser)
       <> group "search" "Search synced tap catalogues (no network refresh)"
          (SearchPlugins <$> (maybe "" id <$> optional (strArgument (metavar "QUERY"))))
       <> group "list" "List installed plugin names" (ListPlugins <$> pluginEvolution)
       <> group "show" "Show vendored package details without compiling the plugin"
          (ShowPlugin <$> pluginArgument <*> pluginEvolution)
       <> group "guide" "Read the plugin's packaged guide without compiling it"
          (ReadPluginGuide <$> argument (eitherReader guideSelection) (metavar "PLUGIN|TAP/PLUGIN") <*> pluginEvolution)
       <> group "connector" "Inspect configured connectors" (Connector <$> connectorParser)))
    <> group "evidence" "Fetch and inspect current evidence and history" (Evidence <$> evidenceParser)
    <> group "secret" "Manage checkout-local secrets" (Secret <$> secretParser)
    <> group "evolution" "Prepare and accept changes" (Evolution <$> evolutionParser))

tapParser :: Parser TapCommand
tapParser = hsubparser
  (group "list" "List taps and their synced catalogue revisions" (pure ListTaps)
  <> group "add" "Declare a tap without fetching it" (AddTap <$> name <*> option (eitherReader gitUrl) (long "from" <> metavar "URL"))
  <> group "remove" "Remove a declaration, leaving installed plugins unchanged" (RemoveTap <$> name)
  <> group "update" "Download or refresh tap catalogues" (UpdateTaps <$> optional name))
  where name = argument (eitherReader tapName) (metavar "NAME")

pluginInstallParser :: Parser PluginCommand
pluginInstallParser = build <$> option (eitherReader evolutionId) (long "evolution" <> metavar "ID")
  <*> ((Left <$> ((,) <$> strOption (long "from" <> metavar "SOURCE" <> help "Local checkout directory or Git URL")
    <*> optional (strOption (long "path" <> metavar "SUBDIRECTORY"))))
    <|> (Right <$> argument (eitherReader qualifiedPlugin) (metavar "TAP/PLUGIN")))
  where
    build selectedId (Left (source,path)) = InstallPlugin selectedId source path
    build selectedId (Right (tap,name)) = InstallAvailablePlugin selectedId tap name

guideSelection :: String -> Either String GuideSelection
guideSelection input | '/' `elem` input = uncurry AvailableGuide <$> qualifiedPlugin input
                     | otherwise = InstalledGuide <$> pluginName input

secretParser :: Parser SecretCommand
secretParser = hsubparser
  (group "set" "Store a secret (omitted VALUE reads stdin or a hidden prompt)"
    (SetSecret <$> name <*> optional (SecretArgument <$> strArgument (metavar "VALUE")))
  <> group "list" "List secret names, never values" (pure ListSecrets)
  <> group "show" "Show a masked secret and its length" (ShowSecret <$> name)
  <> group "remove" "Remove a local secret" (RemoveSecret <$> name))
  where name = argument (eitherReader secretName) (metavar "NAME")

connectorParser :: Parser ConnectorCommand
connectorParser = hsubparser
  (group "list" "List a plugin's configured instances" (ListConnectors <$> plugin <*> evolution)
  <> group "login" "Authenticate a configured connector" (LoginConnector <$> plugin <*> instanceName)
  <> group "show" "Show an instance's fetch options type" (ShowConnector <$> plugin <*> instanceName <*> evolution)
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

pluginEvolution :: Parser (Maybe EvolutionId)
pluginEvolution = optional (option (eitherReader evolutionId)
  (long "evolution" <> metavar "ID" <> help "Read an evolution target instead of the accepted root"))

evidenceParser :: Parser EvidenceCommand
evidenceParser = hsubparser
  (group "fetch" "Fetch evidence from an accepted connector instance" (FetchConnector <$> plugin <*> instanceName
    <*> optional (strOption (long "options" <> metavar "DHALL" <> help "Connector-specific fetch options as hermetic Dhall"))
    <*> flag ContinueSync RestartSync (long "restart-sync" <> help "Start a fresh sync while keeping existing evidence for comparison"))
  <> group "list" "List current evidence IDs and fingerprints" (ListCurrentEvidence <$> plugin <*> instanceName)
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
  <> group "schema" "Explore reachable root schema types" (RootSchema <$> hsubparser
    (group "list" "List reachable named types" (ListSchemas <$> workspace)
    <> group "show" "Show a type's structure and field roles" (ShowSchema <$> argument nonempty (metavar "TYPE") <*> workspace)))
  <> group "collection" "Explore declared fact collections" (RootCollection <$> hsubparser
    (group "list" "List collections and payload types" (ListCollections <$> workspace)
    <> group "show" "Show a collection's schema, roles and references" (ShowCollection <$> collection <*> workspace)))
  <> group "fact" "Read facts from the validated accepted root" (RootFact <$> hsubparser
    (group "list" "List fact IDs and titles" (ListFacts <$> collection)
    <> group "show" "Show a fact's payload" (ShowFact <$> collection <*> strArgument (metavar "ID"))))
  <> group "recipe" "Discover curation instructions and pending evidence" (RootRecipe <$> recipeParser)
  <> group "tool" "Discover and invoke KB-authored investigation helpers" (RootTool <$> hsubparser
    (group "list" "List registered KB tools" (ListTools <$> workspace)
    <> group "show" "Show a tool's description and Dhall types" (ShowTool <$> name <*> workspace)
    <> group "execute" "Execute an accepted KB tool" (ExecuteTool <$> name
      <*> strOption (long "input" <> metavar "DHALL" <> help "Input value as a hermetic Dhall expression")))))
  where
    collection = argument nonempty (metavar "COLLECTION")
    name = argument (eitherReader methodName) (metavar "TOOL")
    workspace = optional (option (eitherReader evolutionId) (long "evolution" <> metavar "ID" <> help "Inspect an evolution target"))

recipeParser :: Parser RecipeCommand
recipeParser = hsubparser
  (group "list" "List recipes in the accepted root" (pure ListRecipes)
  <> group "show" "Read a recipe's instructions" (ShowRecipe <$> recipe)
  <> group "describe" "Describe a closed flow without running its actions" (DescribeRecipe <$> recipe
    <*> (flag' Dot (long "dot" <> help "Render Graphviz DOT")
      <|> flag' Mermaid (long "mermaid" <> help "Render Mermaid") <|> pure Tree))
  <> group "run" "Run a closed recipe and save a draft evolution" (RunRecipe <$> recipe
    <*> some ((,) <$> pluginArgument <*> argument (eitherReader connectorName) (metavar "INSTANCE")))
  <> group "pending" "Inspect net unacknowledged evidence changes" (hsubparser
    (group "list" "List pending evidence for a recipe and connector instance"
      (ListPendingEvidence <$> recipe <*> pluginArgument <*> argument (eitherReader connectorName) (metavar "INSTANCE")))))
  where
    recipe = argument (eitherReader recipeId) (metavar "RECIPE")

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
