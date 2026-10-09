module WorkspaceTests (workspaceTests) where

import Control.Monad (forM_, unless)
import qualified Data.ByteString as Bytes
import qualified Data.ByteString.Char8 as Char8
import Effectful (runPureEff)
import Kyyn.Domain.FileTree (FileTree, fileTree)
import Kyyn.Domain.Git (gitRevision)
import Kyyn.Domain.Path (relativePath)
import Kyyn.Domain.Workspace
import Kyyn.Plumbing.Interpreter.DhallHandling (runDhallHandling)
import Kyyn.Porcelain.Capability.WorkspaceStore (readWorkspaceSnapshot, encodeWorkspaceSnapshot)
import Kyyn.Porcelain.Interpreter.WorkspaceStore (runWorkspaceStore)

workspaceTests :: IO ()
workspaceTests = do
  initial <- tree entries
  snapshot <- right (readSnapshot initial)
  encoded <- right (runPureEff (runDhallHandling (runWorkspaceStore (encodeWorkspaceSnapshot snapshot))))
  reopened <- right (readSnapshot encoded)
  unless (reopened == snapshot) (fail "Workspace encoding did not preserve projected data")
  stale <- tree [(name, if name == "manifest.dhall" then
    "(" <> bytes <> ") // { extra = [] : List Text }" else bytes) | (name,bytes) <- entries]
  case readSnapshot stale of
    Left _ -> pure ()
    Right _ -> fail "Active workspace accepted an unsupported manifest field"
  revision <- right (gitRevision (replicate 40 'a'))
  before <- tree [("SchemaV1.hs", "before source")]
  target <- tree [("kb.dhall", "unfinished target manifest"), ("src/SchemaV2.hs", "unfinished target source")]
  change <- tree [("Evolution.hs", "unfinished transformation"), ("inputs.csv", "a,b")]
  notes <- tree [("review.md", "please review")]
  unless (snapshot == WorkspaceSnapshot (WorkspaceManifest revision "September" "Import sales" Draft AdHoc) before target change notes)
    (fail "Workspace projection changed manifest, bytes or relative paths")
  let compareWith entries' expected = do
        changed <- tree entries' >>= right . readSnapshot
        unless (matchesCapturedInputs snapshot changed == expected && matchesCapturedInputs changed snapshot == expected)
          (fail ("Incorrect workspace input match: " ++ show entries'))
  compareWith (reverse entries) True
  compareWith (replace "manifest.dhall" ("-- formatting only\n" <> manifest "a" "Draft" "September" "Import sales")) True
  forM_ ["Ready", "Accepted"] $ \state ->
    compareWith (replace "manifest.dhall" (manifest "a" state "September" "Import sales")) True
  compareWith (replace "notes/review.md" "different review") True
  compareWith (replace "manifest.dhall" ("(" <> manifest "a" "Draft" "September" "Import sales" <>
    ") // { kind = < AdHoc | RecipeBased : Text >.RecipeBased \"mail\" }")) False
  recipeSnapshot <- tree (replace "manifest.dhall" ("(" <> manifest "a" "Draft" "September" "Import sales" <>
    ") // { kind = < AdHoc | RecipeBased : Text >.RecipeBased \"mail\" }")) >>= right . readSnapshot
  recipeEncoded <- right (runPureEff (runDhallHandling (runWorkspaceStore (encodeWorkspaceSnapshot recipeSnapshot))))
  recipeReopened <- right (readSnapshot recipeEncoded)
  unless (recipeSnapshot == recipeReopened) (fail "Recipe selection was lost on workspace roundtrip")
  tree (replace "manifest.dhall" ("(" <> manifest "a" "Draft" "September" "Import sales" <>
    ") // { kind = < AdHoc | RecipeBased : Text >.RecipeBased \"../mail\" }")) >>= rejected . readSnapshot
  compareWith (filter ((/= "notes/review.md") . fst) entries) True
  compareWith (("notes/new.md", "another note") : entries) True
  forM_ ["archived record", "malformed archived record"] $ \record ->
    compareWith (("result.dhall", record) : entries) True
  forM_ [ manifest "b" "Draft" "September" "Import sales"
        , manifest "a" "Draft" "October" "Import sales"
        , manifest "a" "Draft" "September" "Correct sales"
        ] $ \edited -> compareWith (replace "manifest.dhall" edited) False
  forM_ ["before/SchemaV1.hs", "target/kb.dhall", "target/src/SchemaV2.hs", "change/Evolution.hs", "change/inputs.csv"] $ \path -> do
    compareWith (replace path "same type, changed contents") False
    compareWith (filter ((/= path) . fst) entries) False
  forM_ ["before/Helper.hs", "target/config/plugin.dhall", "change/new.csv"] $ \path ->
    compareWith ((path, "new input") : entries) False
  forM_ ["target/facts/root.dhall", "target/facts", "target/recipes.dhall", "target/recipes/mail/state.dhall", "random/file", "notes", "result.dhall/child"] $ \path ->
    tree ((path, "unexpected") : filter ((/= "notes/review.md") . fst) entries) >>= rejected . readSnapshot
  forM_ ["True", "./other.dhall", Bytes.pack [255], manifest "0" "Draft" "September" "Import sales",
    manifest "a" "Unknown" "September" "Import sales"] $ \bad ->
    tree (replace "manifest.dhall" bad) >>= rejected . readSnapshot
  tree (filter ((/= "manifest.dhall") . fst) entries) >>= rejected . readSnapshot
  -- Capturing an unfinished draft must not try to compile its target or entry.
  draft <- tree [("manifest.dhall", manifest "a" "Draft" "New" "Work in progress")]
  _ <- right (readSnapshot draft)
  illegalTarget <- tree [("facts/root.dhall", "parallel facts")]
  let WorkspaceSnapshot definition beforeFiles _ changeFiles noteFiles = snapshot
  rejected (runPureEff (runDhallHandling (runWorkspaceStore
    (encodeWorkspaceSnapshot (WorkspaceSnapshot definition beforeFiles illegalTarget changeFiles noteFiles)))))
  putStrLn "Workspace manifest, projection and captured-input matching checks passed."
  where
    readSnapshot = runPureEff . runDhallHandling . runWorkspaceStore . readWorkspaceSnapshot
    replace path bytes = [(p, if p == path then bytes else b) | (p,b) <- entries]

entries :: [(FilePath, Bytes.ByteString)]
entries =
  [ ("manifest.dhall", manifest "a" "Draft" "September" "Import sales")
  , ("before/SchemaV1.hs", "before source")
  , ("target/kb.dhall", "unfinished target manifest")
  , ("target/src/SchemaV2.hs", "unfinished target source")
  , ("change/Evolution.hs", "unfinished transformation")
  , ("change/inputs.csv", "a,b")
  , ("notes/review.md", "please review")
  ]

manifest :: String -> String -> String -> String -> Bytes.ByteString
manifest digit state name explanation = Char8.pack
  ("{ before = { revision = " ++ show (concat (replicate 40 digit)) ++ " }, name = " ++ show name ++
   ", explanation = " ++ show explanation ++ ", state = < Draft | Ready | Accepted >." ++ state ++
   ", kind = < AdHoc | RecipeBased : Text >.AdHoc }")

tree :: [(FilePath, Bytes.ByteString)] -> IO FileTree
tree entries' = traverse (\(p,b) -> do path <- right (relativePath p); pure (path,b)) entries' >>= right . fileTree

right :: Show e => Either e a -> IO a
right = either (fail . show) pure

rejected :: Show a => Either e a -> IO ()
rejected (Left _) = pure ()
rejected (Right value) = fail ("Unexpected success: " ++ show value)
