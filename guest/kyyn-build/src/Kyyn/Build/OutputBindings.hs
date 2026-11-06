{-# LANGUAGE OverloadedStrings, OverloadedRecordDot #-}
module Kyyn.Build.OutputBindings (writeOutputBindings) where

import Control.Monad (forM, when)
import Data.List (nub)
import Data.Char (isAlphaNum)
import qualified Data.Text as Text
import qualified Data.Text.IO as Text
import System.Directory (doesFileExist)
import System.FilePath ((</>))
import Kyyn.Build.Manifest
import Kyyn.Build.Plugins
import qualified Kyyn.Types.Plugin as P

-- GHC checks the query result against the sink's actual input type, including
-- private types. The host never prints inspected type names into adapters.
writeOutputBindings :: FilePath -> [FilePath] -> [RegisteredPlugin] -> Manifest -> IO [String]
writeOutputBindings generated roots plugins manifest
  | null manifest.outputs = pure []
  | otherwise = do
      occupied <- or <$> traverse doesFileExist [root </> "KyynOutputBindings" ++ extension | root <- roots, extension <- [".hs",".lhs"]]
      when occupied (fail "Authored source collides with generated module KyynOutputBindings")
      bindings <- forM (zip [0 :: Int ..] manifest.outputs) $ \(index,Output name _ queryName pluginName instanceName method) -> do
        let problem message = fail ("Output " ++ Text.unpack name ++ ": " ++ message)
        when (method /= "publish") (problem "sink method must be publish")
        query <- case [q | q <- manifest.queries, q.queryName == queryName] of
          [selected] -> pure selected
          _ -> problem "unknown registered query"
        declarations <- case [connectors | RegisteredPlugin plugin connectors <- plugins, plugin.pluginName == pluginName] of
          [selected] -> pure selected
          _ -> problem "unknown installed plugin"
        let configPath = "plugins/config/" ++ Text.unpack pluginName ++ ".dhall"
        exists <- doesFileExist configPath
        instances <- if exists then Text.readFile configPath >>= either problem pure . parseInstances else pure []
        connector <- case [selected.instanceConnector | selected <- instances, selected.instanceName == instanceName] of
          [selected] -> pure selected
          _ -> problem "unknown configured sink instance"
        publication <- case [selected | selected <- declarations, selected.name == connector] of
          [P.SinkConnector _ _ publish _] -> either problem pure (qualifiedReference False publish)
          [P.SourceConnector{}] -> problem "selected connector is a source"
          _ -> problem "unknown sink connector"
        let bindingName = "output_" ++ map (\c -> if isAlphaNum c then c else '_') (Text.unpack name) ++ "_" ++ show index
        pure ([referenceModule query.queryImplementation,referenceModule publication],
          ["-- kb.dhall output " ++ show name ++ ": query " ++ show queryName ++
             " (" ++ Text.unpack (referenceName query.queryImplementation) ++ ") -> " ++
             show pluginName ++ "/" ++ show instanceName ++ ".publish (" ++ Text.unpack (referenceName publication) ++ ")",
           bindingName ++ " :: ()",
           bindingName ++ " = matchOutput " ++ Text.unpack (referenceName query.queryImplementation) ++
             " " ++ Text.unpack (referenceName publication)])
      let imports = ["import qualified " ++ Text.unpack name | name <- nub (concatMap fst bindings)]
      writeFile (generated </> "KyynOutputBindings.hs") (unlines
        (["module KyynOutputBindings where", "import Kyyn.Types.Query (Query)",
          "import Kyyn.Plugin.Sink (Sink, SinkError)"] ++ imports ++
         ["matchOutput :: (args -> Query root input) -> (config -> options -> input -> Sink (Either SinkError result)) -> ()",
          "matchOutput _ _ = ()"] ++ concatMap snd bindings))
      pure ["KyynOutputBindings"]
