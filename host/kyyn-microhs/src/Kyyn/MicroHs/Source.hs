module Kyyn.MicroHs.Source (readParsedSource) where

import MicroHs.Expr (EModule)
import MicroHs.Flags (Flags(..))
import MicroHs.Parse (parse, pTop)
import System.FilePath ((</>))
import System.Process (readProcess)

readParsedSource :: Flags -> FilePath -> IO (Either String (EModule,String))
readParsedSource flags path = do
  original <- readFile path
  source <- if hasCpp original then
    readProcess (mhsdir flags </> "bin/cpphs")
      (["--strip", "--noline", "-D__MHS__", "-I" ++ (mhsdir flags </> "src/runtime")]
        ++ cppArgs flags ++ [path]) ""
    else pure original
  pure ((\parsed -> (parsed,source)) <$> parse pTop path source)

hasCpp :: String -> Bool
hasCpp [] = False
hasCpp ('{':'-':'#':rest) =
  let (pragma,following) = span (/= '#') rest
  in "CPP" `elem` words (map (\c -> if c == ',' then ' ' else c) pragma) || hasCpp following
hasCpp (_:rest) = hasCpp rest
