module Main where

import Control.Monad (unless, forM_)
import Data.Char (isAlpha, isAlphaNum, isLower, isSpace)
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
      matches m n ns = [s | s@(ApiSymbol name space _ _ _ _) <- symbolsIn m, name == n, space == ns]
  assert "SDK module inventory" (map (\(ApiModule name _) -> name) modules == public)
  implicit <- inspect ((repo </> "host/kyyn-microhs/test/api-docs"):sources) ["Kyyn.ImplicitExports"]
  let implicitNames = [n | ApiModule _ symbols <- implicit, ApiSymbol n _ _ _ _ _ <- symbols]
  assert "implicit exports hide instance machinery" (all (\n -> not ("inst$" `isInfixOf` n || "@" `isInfixOf` n)) implicitNames)
  assert "source operators and apostrophes remain discoverable" (all (`elem` implicitNames) ["$", "named'", "Public"])
  cpp <- inspect ((repo </> "host/kyyn-microhs/test/api-docs"):sources) ["Kyyn.CppFixture"]
  assert "CPP signature and documentation use compiler branch" (case cpp of
    [ApiModule _ [ApiSymbol "selected" ValueNamespace _ _ (Just "selected :: String")
      (Just "The MicroHs branch, including its source documentation.")]] -> True
    _ -> False)
  assert "private function leaked" (null (matches "Kyyn.Edit" "unique" ValueNamespace))
  assert "abstract constructor leaked" (null (matches "Kyyn.Edit" "Collection" ValueNamespace))
  assert "abstract type missing" (length (matches "Kyyn.Edit" "Collection" TypeNamespace) == 1)
  assert "constructor namespace lost" (length (matches "Kyyn.Types.Fact" "Fact" ValueNamespace) == 1
    && length (matches "Kyyn.Types.Fact" "Fact" TypeNamespace) == 1)
  assert "record selector missing" (not (null (matches "Kyyn.Types.Evolution" "explanation" ValueNamespace)))
  let update = matches "Kyyn.Edit" "update" ValueNamespace
  assert "signature precedence/aliases" (case update of
    [ApiSymbol _ _ "Kyyn.Edit.update" _ (Just "update :: FactId -> Edit a r -> CollectionEdit a r") _] -> True
    _ -> False)
  assert "reexport origin/signature" (matches "Kyyn.Evolution" "update" ValueNamespace == update)
  assert "SDK documentation is attached to the signature" (case update of
    [ApiSymbol _ _ _ _ _ (Just docs)] -> "Fails if the ID is missing or ambiguous." `isInfixOf` docs
    _ -> False)
  forM_ public $ \m ->
    forM_ [s | s@(ApiSymbol n ns origin _ declaration _) <- symbolsIn m,
              ns == TypeNamespace || (declaration /= Nothing && authoredFunction n origin)] $ \s ->
      assert ("Missing documentation on authored SDK declaration: " ++ show s)
        (case s of ApiSymbol _ _ _ _ _ (Just text) -> not (null text); _ -> False)
  docs <- inspect ((repo </> "host/kyyn-microhs/test/api-docs"):sources) ["Kyyn.DocFixture","Kyyn.DocReexport"]
  let docsIn m = [(n,ns,d) | ApiModule moduleName symbols <- docs, moduleName == m,
                            ApiSymbol n ns _ _ _ d <- symbols]
      documentationFor n ns = [d | (name,namespace,d) <- docsIn "Kyyn.DocFixture", name == n, namespace == ns]
  assert "reexport documentation" (docsIn "Kyyn.DocFixture" == docsIn "Kyyn.DocReexport")
  assert "multiline, Unicode and indentation" (documentationFor "documented" ValueNamespace ==
    [Just "Return the supplied text: café.\n\n  An indented example."])
  assert "ordinary comments excluded" (documentationFor "ordinary" ValueNamespace == [Nothing])
  assert "blank line detaches documentation" (documentationFor "detached" ValueNamespace == [Nothing])
  assert "type documentation" (documentationFor "Item" TypeNamespace == [Just "An abstract item. Its constructor stays private."])
  assert "private constructor still excluded" (null (documentationFor "PrivateItem" ValueNamespace))
  assert "alias documentation" (documentationFor "Alias" TypeNamespace == [Just "A documented alias."])
  dataModules <- inspect ((repo </> "host/kyyn-microhs/test/api-docs"):sources)
    ["Kyyn.DataFixture", "Kyyn.DataReexport"]
  let declarationIn m n = case [d | ApiModule name symbols <- dataModules, name == m,
          ApiSymbol name' TypeNamespace _ _ (Just d) _ <- symbols, name' == n] of
        [d] -> d
        _ -> error ("Missing data declaration: " ++ m ++ "." ++ n)
      originalDeclaration = declarationIn "Kyyn.DataFixture"
  assert "public record fields" (all (`isInfixOf` originalDeclaration "Record") ["title", "count", "String", "Int"])
  assert "abstract data header" (words (originalDeclaration "Abstract") == ["data", "Abstract"])
  assert "abstract newtype header" (words (originalDeclaration "AbstractNew") == ["newtype", "AbstractNew"])
  assert "partial constructors" ("Visible" `isInfixOf` originalDeclaration "Partial"
    && not ("Secret" `isInfixOf` originalDeclaration "Partial"))
  assert "private record selectors" (not ("hidden" `isInfixOf` originalDeclaration "HiddenFields"))
  assert "selective constructor reexport" ("Empty" `isInfixOf` declarationIn "Kyyn.DataReexport" "Choice"
    && not ("Full" `isInfixOf` declarationIn "Kyyn.DataReexport" "Choice"))
  assert "abstract record reexport" (words (declarationIn "Kyyn.DataReexport" "Record") == ["data", "Record"])
  withSystemTempDirectory "kyyn-api-data-" $ \temporary -> do
    createDirectoryIfMissing True (temporary </> "Kyyn")
    writeFile (temporary </> "Kyyn/PresentedData.hs") (unlines
      (["{-# LANGUAGE GADTs, ExistentialQuantification #-}", "module Kyyn.PresentedData where"]
      ++ map originalDeclaration ["Choice", "Record", "Wrapped", "Partial", "HiddenFields", "Expr"]))
    presented <- inspect [temporary] ["Kyyn.PresentedData"]
    let constructors name modules' = [(n,alphaSignature t) | ApiModule m symbols <- modules', m == name,
          ApiSymbol n ValueNamespace _ t _ _ <- symbols,
          n `elem` ["Empty", "Full", "Record", "Wrapped", "Visible", "HiddenFields", "Number", "Apply"]]
    assert "presented constructors recompile with unchanged types"
      (constructors "Kyyn.DataFixture" dataModules == constructors "Kyyn.PresentedData" presented)
  assert "CPP-backed upstream signature" (case matches "Kyyn.Edit" "modify" ValueNamespace of
    [ApiSymbol _ _ "Control.Monad.Trans.State.Strict.modify" _ (Just signature) _] ->
      signature == "modify :: Monad m => (s -> s) -> StateT s m ()"
    _ -> False)
  assert "operator declaration must parse" (case matches "Kyyn.Evolution" ">=>" ValueNamespace of
    [ApiSymbol _ _ _ _ (Just declaration) _] -> "(>=>) ::" `isInfixOf` declaration
    _ -> False)
  let signature m n = case matches m n ValueNamespace of
        [ApiSymbol _ _ _ _ (Just text) _] -> text
        _ -> error ("Missing source signature: " ++ m ++ "." ++ n)
  assert "constructor keeps String alias" (signature "Kyyn.Types.Fact" "FactId" == "FactId :: String -> FactId")
  assert "selector keeps String alias" (signature "Kyyn.Types.Evidence" "source" == "source :: EvidenceRef -> String")
  assert "constructor eliminates trivial GADT equalities"
    (signature "Kyyn.Types.Query" "ReadCollection" == "ReadCollection :: CollectionBinding root fact -> SnapshotRead root [Fact fact]")
  assert "constructor restores GADT parameters"
    (signature "Kyyn.Types.Program" "Pure" == "Pure :: a -> Program request a")
  withSystemTempDirectory "kyyn-api-values-" $ \temporary -> do
    createDirectoryIfMissing True (temporary </> "Kyyn")
    let symbols = nubBy sameOrigin (concatMap symbolsIn public)
        signatures = [(n,d) | ApiSymbol n ValueNamespace origin _ (Just d) _ <- symbols,
          not (authoredFunction n origin)]
        valueName n@(c:_) | isAlpha c || c == '_' = n
        valueName n = "(" ++ n ++ ")"
        witness (i,(n,d)) = ["proof" ++ show i ++ dropWhile (/= ':') d,
          "proof" ++ show i ++ " = " ++ valueName n]
    writeFile (temporary </> "Kyyn/ValueProof.hs") (unlines
      (["{-# LANGUAGE GADTs, RankNTypes #-}", "module Kyyn.ValueProof where",
        "import Control.Monad.Trans.State.Strict (StateT)"]
      ++ map ("import " ++) public ++ concatMap witness (zip [1 :: Int ..] signatures)))
    _ <- inspect (temporary:sources) ["Kyyn.ValueProof"]
    pure ()
  withSystemTempDirectory "kyyn-api-" $ \temporary -> do
    let unique = nubBy sameOrigin (concatMap symbolsIn public)
        declarations = [(n,ns,origin,decl) | ApiSymbol n ns origin _ (Just decl) _ <- unique,
          not ("data " `isPrefixOf` decl || "newtype " `isPrefixOf` decl),
          ns == TypeNamespace || authoredFunction n origin]
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
      let signatures symbols = [(n,ns,origin,t) | ApiSymbol n ns origin t _ _ <- symbols]
      assert ("Displayed declarations changed checked exports of " ++ m)
        (signatures before == signatures after)
      assert ("Signature substitution displaced documentation in " ++ m)
        ([(n,ns,d) | ApiSymbol n ns _ _ _ d <- before] == [(n,ns,d) | ApiSymbol n ns _ _ _ d <- after])
    putStrLn ("Recompiled the SDK with all " ++ show (length declarations)
      ++ " displayed signatures/aliases substituted; all checked exports unchanged.")
  missing <- inspectApi (repo </> "vendor/MicroHs") sources ["Kyyn.Missing"]
  assert "missing module must be a compiler error" (case missing of Left (ApiCompilerError _) -> True; _ -> False)
  putStrLn "Guest API exports, reexports, abstraction, aliases and signature round trips passed."
  where sameOrigin (ApiSymbol _ ns a _ _ _) (ApiSymbol _ ns' b _ _ _) = (ns,a) == (ns',b)

authoredFunction :: String -> String -> Bool
authoredFunction name origin = "Kyyn." `isPrefixOf` origin && not (".get$." `isInfixOf` origin)
  && case name of c:_ -> isLower c || (not (isAlpha c) && c /= ':'); [] -> False

assert :: String -> Bool -> IO ()
assert label ok = unless ok (fail label)

-- These fixture signatures have no shadowed binders. Canonicalize variable
-- tokens, including fresh kind variables, without changing constructors/operators.
alphaSignature :: String -> [String]
alphaSignature source = map canonical tokens
  where
    tokens = tokenize source
    variable (c:_) = isLower c || c == '_'
    variable [] = False
    variables = nub [t | t <- tokens, variable t, t /= "forall"]
    canonical t = maybe t (('v':) . show) (lookup t (zip variables [0 :: Int ..]))
    tokenize [] = []
    tokenize (c:cs) | isSpace c = tokenize cs
    tokenize s@(c:cs)
      | isAlpha c || c == '_' = let (name,rest) = span (\x -> isAlphaNum x || x `elem` "_'$") s
                               in name : tokenize rest
      | otherwise = [c] : tokenize cs

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
