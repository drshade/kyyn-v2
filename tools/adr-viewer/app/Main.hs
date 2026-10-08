-- | adr-viewer: extract evidence from history, check curated lanes, render HTML.
module Main (main) where

import AdrViewer.Check
import AdrViewer.Extract
import AdrViewer.Json (encodeCompact)
import AdrViewer.Pending
import AdrViewer.Types (stepSeq)
import qualified Data.ByteString.Lazy.Char8 as BLC
import AdrViewer.Render (renderPage)
import qualified Data.ByteString.Lazy as BL
import qualified Data.Text.IO as TIO
import Options.Applicative
import System.Exit (exitFailure)
import System.IO (hPutStrLn, stderr)

data Command
  = Extract ExtractOptions
  | Check FilePath FilePath
  | Pending FilePath FilePath Bool
  | Render FilePath FilePath FilePath

main :: IO ()
main = execParser (info (commands <**> helper) (fullDesc <> progDesc "Plan-versus-build history of a repository's ADRs")) >>= run

commands :: Parser Command
commands = hsubparser $ mconcat
  [ command "extract" (info extractOpts (progDesc "Write mechanical evidence from git and GitHub history"))
  , command "check" (info (Check <$> evidenceOpt <*> curatedOpt) (progDesc "Validate curated lanes against the evidence"))
  , command "pending" (info (Pending <$> evidenceOpt <*> curatedOpt
        <*> switch (long "json" <> help "Machine-readable output"))
      (progDesc "List, per lane, the steps after its cursor and the open decisions they could realise"))
  , command "render" (info (Render <$> evidenceOpt <*> curatedOpt <*> outputOpt "HTML file to write")
      (progDesc "Check, then write the self-contained time-travel page")) ]
  where
    extractOpts = fmap Extract $ ExtractOptions
      <$> strOption (long "repo" <> metavar "DIR" <> value "." <> showDefault <> help "Repository to read")
      <*> strOption (long "branch" <> metavar "REF" <> value "main" <> showDefault <> help "Branch whose first-parent history is walked")
      <*> outputOpt "Evidence directory to write"
    evidenceOpt = strOption (long "evidence" <> metavar "DIR" <> value "evidence" <> showDefault <> help "Evidence directory")
    curatedOpt = strOption (long "curated" <> metavar "DIR" <> value "curated" <> showDefault <> help "Curated directory")
    outputOpt h = strOption (long "output" <> metavar "PATH" <> help h)

run :: Command -> IO ()
run (Extract opts) = extract opts
run (Check evidence curated) = do
  inputs <- load evidence curated
  report inputs
  putStrLn (show (length (inLanes inputs)) <> " lanes checked")
run (Pending evidence curated asJson) = do
  inputs <- load evidence curated
  let lastSeq = maximum (0 : map stepSeq (inSteps inputs))
      work = pending inputs
  if asJson then BLC.putStrLn (encodeCompact (pendingJson lastSeq work))
            else TIO.putStr (renderPending lastSeq work)
run (Render evidence curated output) = do
  inputs <- load evidence curated
  report inputs
  BL.writeFile output (renderPage inputs)
  putStrLn ("wrote " <> output)

load :: FilePath -> FilePath -> IO Inputs
load evidence curated = loadInputs evidence curated >>= either (\es -> mapM_ putErr es >> exitFailure) pure
  where putErr e = hPutStrLn stderr ("error: " <> e)

-- | Print every diagnostic; errors stop the command.
report :: Inputs -> IO ()
report inputs = do
  let ds = checkInputs inputs
  mapM_ (TIO.hPutStrLn stderr . renderDiagnostic) ds
  if any ((== Error) . dSeverity) ds then exitFailure else pure ()
