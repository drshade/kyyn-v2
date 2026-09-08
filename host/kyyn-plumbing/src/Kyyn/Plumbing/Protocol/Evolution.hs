module Kyyn.Plumbing.Protocol.Evolution (evolutionBindings, identityEvolutionSource) where

import Control.Monad (unless)
import Data.List (nub, intercalate)
import Data.ByteString (ByteString)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import Kyyn.Domain.Contract (RootContract, rootSchema, rootType, contractId, contractFingerprint)
import Kyyn.Domain.DataType (DataType(..), haskellType, definingModule, reachableTypes)
import Kyyn.Domain.FileTree (FileTree, fileTree)
import Kyyn.Domain.Path (relativePath)
import Kyyn.Plumbing.Capability.GuestCompilation.Types (bindingModule)
import Kyyn.Plumbing.Capability.SchemaInspection.Codecs (generateCodecs)

identityEvolutionSource :: ByteString
identityEvolutionSource = Text.encodeUtf8 (Text.pack (unlines
  [ "module Evolution where"
  , "import Kyyn.Evolution (EvolutionFailure, EvolutionOutput, evaluateEvolution, identityEvolution)"
  , "import Kyyn.Types.Program (Program)"
  , ""
  , "evolution :: root -> Program calls (Either EvolutionFailure (EvolutionOutput root))"
  , "evolution = pure . evaluateEvolution identityEvolution"
  ]))

evolutionBindings :: [(String, RootContract)] -> Either String FileTree
evolutionBindings declarations = do
  let names = map fst declarations
  unless (not (null names) && length names == length (nub names)) (Left "Evolution bindings must be nonempty and uniquely named")
  mapM_ (bindingModule . ("KyynEvolutionBindings." ++)) names
  codecs <- sequence [do
    source <- generateCodecs (codecName index) (rootType (rootSchema contract))
    path <- relativePath (codecName index ++ ".hs")
    pure (path,utf8 source) | (index,(_,contract)) <- zip [0..] declarations]
  path <- relativePath "KyynEvolutionBindings.hs"
  let source = unlines $
        ["module KyynEvolutionBindings (" ++ intercalate ", " names ++ ") where",
         "import Kyyn.Evolution.Internal (RootBinding(..))", "import Kyyn.Runtime.Json (encodeWith)"] ++
        ["import qualified " ++ name | name <- nub [definingModule name |
          (_,contract) <- declarations, Algebraic name _ _ <- reachableTypes (rootType (rootSchema contract))]] ++
        ["import qualified " ++ codecName index | (index,_) <- zip [0..] declarations] ++
        concat [[name ++ " :: RootBinding " ++ haskellType (rootType (rootSchema contract)),
          name ++ " = RootBinding " ++ show (contractFingerprint (contractId (rootSchema contract))) ++
          " (encodeWith " ++ codecName index ++ ".rootCodec)"] | (index,(name,contract)) <- zip [0..] declarations]
  fileTree ((path,utf8 source):codecs)
  where
    codecName :: Int -> String
    codecName index = "KyynEvolutionCodec" ++ show index
    utf8 = Text.encodeUtf8 . Text.pack
