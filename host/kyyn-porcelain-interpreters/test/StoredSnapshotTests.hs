-- Real hermetic Dhall storage decoding without any compiler/root inspection.
-- Covers path identities, membership integrity, inferred empty types and recipe
-- state presence; target decoding/validation and publication are separate tests.
{-# LANGUAGE OverloadedStrings #-}
module Main (main) where

import Control.Monad (unless, forM_)
import Data.Aeson (Value(..))
import qualified Data.ByteString as Bytes
import Data.Either (isLeft)
import Effectful (runPureEff)
import Kyyn.Domain.DataType
import Kyyn.Domain.FileTree (fileTree)
import Kyyn.Domain.Path (relativePath)
import Kyyn.Domain.StoragePath
import Kyyn.Domain.StoredSnapshot
import Kyyn.Domain.Recipe (RecipeDefinition(..))
import Kyyn.Types.Fact (Fact(..), FactId(..))
import Kyyn.Types.KnowledgeBase (FlowEntryRef(..))
import Kyyn.Plumbing.Interpreter.DhallHandling (runDhallHandling)
import Kyyn.Porcelain.Protocol.RecipePersistence (encodeRecipes)
import Kyyn.Porcelain.Protocol.SnapshotWire
import Kyyn.Porcelain.Protocol.StoredSnapshot

main :: IO ()
main = do
  recipeBytes <- right (runPureEff (runDhallHandling (encodeRecipes
    [Fact (FactId "weekly") (ClosedRecipe (FlowEntryRef "BrokenFlow.run"))])))
  let original =
        [("facts/root.dhall", "{ optional = None Text, names = [] : List Text }")
        ,("facts/people/index.dhall", "[\"a\", \"b\"]")
        ,("facts/people/a.dhall", "{ id = \"a\", value = { name = \"Alice\" } }")
        ,("facts/people/b.dhall", "{ id = \"b\", value = { name = \"Bob\" } }")
        ,("facts/empty/index.dhall", "[] : List Text")
        ,("recipes.dhall", recipeBytes)
        ,("recipes/weekly/state.dhall", "{ seen = [] : List Text }")
        ,("src/BrokenFlow.hs", "this deliberately cannot compile")
        ,("kb.dhall", "this is deliberately not a valid manifest")]
      replace path bytes = [(name,if name == path then bytes else value) | (name,value) <- original]
      without path = filter ((/= path) . fst) original
      reject label input = assert label (isLeft (readSnapshot input))
  snapshot@(StoredSnapshot fields collections recipes) <- right (readSnapshot original)
  wire <- right (encodeSnapshotWire snapshot)
  decoded <- right (runPureEff (runDhallHandling (decodeSnapshotWire wire)))
  assert "structural transport changes captured data" (snapshot == decoded)
  assert "annotated empty types lost" (case (lookup "names" fields,lookup "optional" fields) of
    (Just (RecordedValue (List (Scalar TextScalar)) (Array _)),
     Just (RecordedValue (Optional (Scalar TextScalar)) _)) -> True
    _ -> False)
  assert "membership order lost" (case lookup "people" collections of
    Just members -> [identity | Fact identity _ <- members] == [FactId "a",FactId "b"]
    _ -> False)
  assert "empty collection lost" (lookup "empty" collections == Just [])
  assert "closed recipe needs no executable" (case recipes of
    [Fact (FactId "weekly") (RecordedRecipe (ClosedRecipe (FlowEntryRef "BrokenFlow.run")) _)] -> True
    _ -> False)
  reject "duplicate IDs accepted" (replace "facts/people/index.dhall" "[\"a\",\"a\"]")
  reject "missing listed file accepted" (without "facts/people/a.dhall")
  reject "unlisted file accepted" (original ++ [("facts/people/c.dhall", "{ id = \"c\", value = {=} }")])
  reject "mismatched envelope accepted" (replace "facts/people/a.dhall" "{ id = \"b\", value = {=} }")
  reject "extra envelope fields accepted" (replace "facts/people/a.dhall" "{ id = \"a\", value = {=}, extra = True }")
  reject "missing state accepted" (without "recipes/weekly/state.dhall")
  reject "unlisted state accepted" (original ++ [("recipes/other/state.dhall", "{=}")])
  reject "state import accepted" (replace "recipes/weekly/state.dhall" "./other.dhall")
  reject "malformed state accepted" (replace "recipes/weekly/state.dhall" "None")
  reject "non-record residual accepted" (replace "facts/root.dhall" "[] : List Text")
  reject "unsupported storage type accepted" (replace "facts/root.dhall" "{ real = 1.5 }")
  reject "noncanonical collection path accepted"
    ([("facts/~70656f706c65/" ++ drop (length ("facts/people/" :: String)) name,value)
       | (name,value) <- original, take 13 name == "facts/people/"] ++
      filter (\(name,_) -> take 13 name /= "facts/people/") original)
  forM_ ["people", "Some people", "index", "con", "λ", "", "a/b", "~"] $ \name ->
    assert "storage path roundtrip failed" (decodeComponent (encodeComponent name) == Right name)
  forM_ ["~6", "~gg", "~FF", "~61", "Some people", "index"] $ \name ->
    assert "noncanonical path accepted" (isLeft (decodeComponent name))
  putStrLn "Stored snapshot checks passed"

readSnapshot :: [(String,Bytes.ByteString)] -> Either String StoredSnapshot
readSnapshot entries = do
  paths <- traverse (\(name,value) -> (,value) <$> relativePath name) entries
  tree <- fileTree paths
  either (Left . show) Right (runPureEff (runDhallHandling (readStoredSnapshot tree)))

assert :: String -> Bool -> IO ()
assert label condition = unless condition (fail label)

right :: Show e => Either e a -> IO a
right = either (fail . show) pure
