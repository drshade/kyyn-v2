module Kyyn.Plumbing.Protocol.Evolution (identityEvolutionSource) where
import Data.ByteString (ByteString)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import Kyyn.Domain.DataType (definingModule)

identityEvolutionSource :: String -> ByteString
identityEvolutionSource selected = Text.encodeUtf8 (Text.pack (unlines
  [ "module Evolution where"
  , "import Kyyn.Workspace.Evolution"
  , "import qualified " ++ definingModule selected
  , "import qualified Kyyn.Workspace.Target as Target"
  , ""
  , "evolution :: Evolution " ++ selected
  , "evolution = identityEvolution"
  ]))

