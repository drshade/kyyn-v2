module Tools (Args, Result, count, listCount) where

import Kyyn.Connectors (Tool, files)
import qualified Kyyn.Plugins.P_local_file.Files as Files
import qualified Kyyn.Plugins.P_local_file.Files.Evidence as Evidence
import Kyyn.Plugin (FetchError)
import qualified Kyyn.Agentic

type Args = ()
type Result = Integer

count :: Args -> Tool (Either FetchError Result)
count () = Files.count files ()

listCount :: Args -> Tool (Either FetchError Result)
listCount () = fmap (fmap (toInteger . length)) (Evidence.listEvidenceIds files)
