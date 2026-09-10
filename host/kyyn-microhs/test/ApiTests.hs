module Main where

import Control.Monad (unless, forM_)
import Data.Char (isAlpha, isSpace)
import Data.List (nubBy, isInfixOf, isPrefixOf, nub)
import Kyyn.MicroHs.ApiInspection
import Kyyn.Domain.GuestApi
import System.Environment (getEnv)
import System.Directory (createDirectoryIfMissing, listDirectory, doesDirectoryExist, copyFile)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)

main :: IO ()
main = do
  repo <- getEnv "KYYN_TEST_ROOT"
  let sources = map (repo </>) ["guest/kyyn-sdk/src","shared/kyyn-types/src","vendor/transformers","vendor/json"]
      public = ["Kyyn.Edit", "Kyyn.Evolution", "Kyyn.Optics", "Kyyn.Types.SchemaMetadata", "Kyyn.Types.Fact",
        "Kyyn.Types.Diagnostic", "Kyyn.Types.Program", "Kyyn.Types.Query", "Kyyn.Types.Evidence", "Kyyn.Types.Evolution"]
      inspect paths names = inspectApi (repo </> "vendor/MicroHs") paths names >>= either (fail . show) pure
  modules <- inspect sources public
  let symbolsIn m = concat [symbols | ApiModule name symbols <- modules, name == m]
      matches m n ns = [s | s@(ApiSymbol name space _ _ _) <- symbolsIn m, name == n, space == ns]
  assert "SDK module inventory" (map (\(ApiModule name _) -> name) modules == public)
  assert "private function leaked" (null (matches "Kyyn.Edit" "unique" ValueNamespace))
  assert "abstract constructor leaked" (null (matches "Kyyn.Edit" "Collection" ValueNamespace))
  assert "abstract type missing" (length (matches "Kyyn.Edit" "Collection" TypeNamespace) == 1)
  assert "constructor namespace lost" (length (matches "Kyyn.Types.Fact" "Fact" ValueNamespace) == 1
    && length (matches "Kyyn.Types.Fact" "Fact" TypeNamespace) == 1)
  assert "record selector missing" (not (null (matches "Kyyn.Types.Evolution" "explanation" ValueNamespace)))
  let update = matches "Kyyn.Edit" "update" ValueNamespace
  assert "signature precedence/aliases" (case update of
    [ApiSymbol _ _ "Kyyn.Edit.update" _ (Just "update :: FactId -> Edit a r -> CollectionEdit a r")] -> True
    _ -> False)
  assert "reexport origin/signature" (matches "Kyyn.Evolution" "update" ValueNamespace == update)
  assert "upstream fallback must remain explicit" (case matches "Kyyn.Edit" "modify" ValueNamespace of
    [ApiSymbol _ _ "Control.Monad.Trans.State.Strict.modify" signature Nothing] -> "StateT" `isInfixOf` signature
    _ -> False)
  assert "operator declaration must parse" (case matches "Kyyn.Evolution" ">=>" ValueNamespace of
    [ApiSymbol _ _ _ _ (Just declaration)] -> "(>=>) ::" `isInfixOf` declaration
    _ -> False)
  withSystemTempDirectory "kyyn-api-" $ \temporary -> do
    let unique = nubBy sameOrigin (concatMap symbolsIn public)
        declarations = [(n,ns,origin,decl) | ApiSymbol n ns origin _ (Just decl) <- unique]
        owner = reverse . drop 1 . dropWhile (/= '.') . reverse
    mapM_ (\directory -> copyTree directory temporary) (take 2 sources)
    forM_ (nub [owner origin | (_,_,origin,_) <- declarations]) $ \m -> do
      let path = temporary </> map (\c -> if c == '.' then '/' else c) m ++ ".hs"
          selected = [(n,ns,decl) | (n,ns,origin,decl) <- declarations, owner origin == m]
      original <- readFile path
      rewritten <- either fail pure (rewrite selected (lines original))
      length rewritten `seq` writeFile path (unlines rewritten)
    roundTrip <- inspect (temporary:sources) public
    forM_ (zip modules roundTrip) $ \(ApiModule m before, ApiModule _ after) -> do
      let signatures symbols = [(n,ns,origin,t) | ApiSymbol n ns origin t _ <- symbols]
      assert ("Displayed declarations changed checked exports of " ++ m)
        (signatures before == signatures after)
    putStrLn ("Recompiled the SDK with all " ++ show (length declarations)
      ++ " displayed signatures/aliases substituted; all checked exports unchanged.")
  missing <- inspectApi (repo </> "vendor/MicroHs") sources ["Kyyn.Missing"]
  assert "missing module must be a compiler error" (case missing of Left (ApiCompilerError _) -> True; _ -> False)
  putStrLn "Guest API exports, reexports, abstraction, aliases and signature round trips passed."
  where sameOrigin (ApiSymbol _ ns a _ _) (ApiSymbol _ ns' b _ _) = (ns,a) == (ns',b)

assert :: String -> Bool -> IO ()
assert label ok = unless ok (fail label)

copyTree :: FilePath -> FilePath -> IO ()
copyTree source destination = do
  createDirectoryIfMissing True destination
  entries <- listDirectory source
  forM_ entries $ \entry -> do
    directory <- doesDirectoryExist (source </> entry)
    if directory then copyTree (source </> entry) (destination </> entry)
    else copyFile (source </> entry) (destination </> entry)

-- Fixture rewriting only: SDK signatures start at column one, with indented
-- continuations. Fail if a declaration cannot be replaced, rather than skip it.
rewrite :: [(String,Namespace,String)] -> [String] -> Either String [String]
rewrite [] source = Right source
rewrite ((name,namespace,declaration):remaining) source = do
  let prefix = case namespace of
        TypeNamespace -> "type " ++ name ++ " "
        ValueNamespace -> (case name of c:_ | isAlpha c || c == '_' -> name; _ -> "(" ++ name ++ ")") ++ " ::"
      (before,found) = break (isPrefixOf prefix) source
      continued line = null line || maybe False isSpace (case line of c:_ -> Just c; _ -> Nothing)
  case found of
    [] -> Left ("SDK fixture declaration not found: " ++ prefix)
    _:rest -> rewrite remaining (before ++ lines declaration ++ dropWhile continued rest)
