module Main where

import Control.Monad (unless)
import qualified Data.ByteString as Bytes
import Data.List (nub, sort)
import Distribution.PackageDescription (condLibrary, exposedModules)
import Distribution.Simple.PackageDescription (readGenericPackageDescription)
import Distribution.Types.CondTree (condTreeData, condTreeComponents)
import Distribution.Pretty (prettyShow)
import Distribution.Verbosity (silent)
import Effectful (runEff)
import Kyyn.MicroHs.ApiInspection (inspectApi)
import Kyyn.Plumbing.Interpreter.DhallHandling (runDhallHandling)
import Kyyn.Plumbing.Protocol.GuestApi (encodeCatalogue)
import System.Environment (getArgs)
import System.FilePath ((</>))

main :: IO ()
main = do
  arguments <- getArgs
  case arguments of
    runtime:packages@(_:_) -> do
      modules <- sort . nub . concat <$> mapM publicModules packages
      catalogue <- inspectApi (runtime </> "microhs") [runtime </> "sdk"] modules
        >>= either (fail . show) pure
      bytes <- runEff (runDhallHandling (encodeCatalogue catalogue)) >>= either (fail . show) pure
      Bytes.writeFile (runtime </> "guest-api.dhall") bytes
      putStrLn ("Generated API catalogue for " ++ show (length modules) ++ " guest modules")
    _ -> fail "Usage: kyyn-api-catalogue RUNTIME_DIRECTORY SDK_PACKAGE.cabal..."

publicModules :: FilePath -> IO [String]
publicModules path = do
  package <- readGenericPackageDescription silent path
  case condLibrary package of
    Nothing -> fail ("No public library in " ++ path)
    Just library -> do
      unless (null (condTreeComponents library))
        (fail ("Conditional SDK module declarations need an explicit build configuration: " ++ path))
      pure (map prettyShow (exposedModules (condTreeData library)))
