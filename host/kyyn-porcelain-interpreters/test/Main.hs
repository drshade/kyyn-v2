module Main (main) where

import Control.Monad (unless, forM_)
import Data.Aeson (Value, object, (.=))
import qualified Data.ByteString as Bytes
import Data.List (isSuffixOf)
import Data.Text (Text)
import Effectful (runPureEff)
import Kyyn.Domain.Contract
import Kyyn.Domain.DataType
import Kyyn.Domain.Path
import Kyyn.Domain.Root
import Kyyn.Types.SchemaMetadata
import Kyyn.Porcelain.Capability.RootStore
import Kyyn.Porcelain.Interpreter.RootStore
import Kyyn.Plumbing.Interpreter.DhallHandling

main :: IO ()
main = do
  contract <- right (checkContract schema metadata)
  other <- right (checkContract schema (SchemaMetadata [RoleDecl "label" "Changed metadata" Title] [] declarations))
  code <- tree [("src/Schema.hs", "authored code"), ("kb.dhall", "selected schema")]
  checked <- right (runPureEff (runDhallHandling (runRootStore (checkRootValue contract value))))
  root@(Root _ snapshot savedCode) <- right (runPureEff (runDhallHandling (runRootStore (materializeRoot contract code checked))))
  unless (savedCode == code) (fail "Code snapshot changed")
  let reopen r = runPureEff (runDhallHandling (runRootStore (loadRootValueForChecking r)))
  reopenedFiles <- right (fileTree (files snapshot))
  reopened <- right (reopen (Root contract reopenedFiles code))
  unless (reopened == checked) (fail "Reopening changed the root")
  rejected (runPureEff (runDhallHandling (runRootStore (materializeRoot other code checked))))
  forM_ [[], [("same","one"),("same","two")]] $ \items -> do
    candidate <- right (runPureEff (runDhallHandling (runRootStore (checkRootValue contract (rootValue items)))))
    case items of
      [] -> do
        empty@(Root _ emptyFiles _) <- right (runPureEff (runDhallHandling (runRootStore (materializeRoot contract code candidate))))
        emptyValue <- right (reopen empty)
        unless (emptyValue == candidate && length (files emptyFiles) == 2) (fail "Empty collection not retained")
      _ -> rejected (runPureEff (runDhallHandling (runRootStore (materializeRoot contract code candidate))))
  forM_ (files snapshot) $ \(path,_) -> do
    missing <- right (fileTree (filter ((/= path) . fst) (files snapshot)))
    rejected (reopen (Root contract missing code))
  extra <- tree [("facts/unlisted.dhall", "{}")]
  unlisted <- right (fileTree (files snapshot ++ files extra))
  rejected (reopen (Root contract unlisted code))
  forM_ ["[\"a\", \"a\"]", "[\"missing\"]", "[\"a\"]", "[\"../\"]", "[] : List Text"] $ \index -> do
    changed <- right (fileTree [(p, if "index.dhall" `isSuffixOf` relativeName p then index else b) | (p,b) <- files snapshot])
    rejected (reopen (Root contract changed code))
  let damage replacement = fileTree [(p, if "f-61.dhall" `isSuffixOf` relativeName p then replacement else b) | (p,b) <- files snapshot]
  forM_ ["{ id = \"wrong\", value = { title = \"one\" } }", Bytes.pack [255]] $ \bad -> do
    corrupt <- right (damage bad)
    rejected (reopen (Root contract corrupt code))
  overlap <- tree [("facts/extra", "not code")]
  rejected (runPureEff (runDhallHandling (runRootStore (materializeRoot contract overlap checked))))
  a <- right (relativePath "a")
  ab <- right (relativePath "a/b")
  rejected (fileTree [(a,""),(a,"")])
  rejected (fileTree [(a,""),(ab,"")])
  unless (root == Root contract snapshot code) (fail "Snapshot mutated")
  putStrLn "Root materialization/reopening, identities, membership and corruption checks passed."

right :: Show e => Either e a -> IO a
right = either (fail . show) pure

rejected :: Show a => Either e a -> IO ()
rejected (Left _) = pure ()
rejected (Right value') = fail ("Unexpected success: " ++ show value')

tree :: [(FilePath, Bytes.ByteString)] -> IO FileTree
tree entries = do
  paths <- traverse (\(p,b) -> do path <- right (relativePath p); pure (path,b)) entries
  right (fileTree paths)

value :: Value
value = rootValue [("a", "one"), ("A/../🌍", "two")]

rootValue :: [(Text,Text)] -> Value
rootValue items = object ["description" .= ("kept outside collections" :: Text), "todos" .=
  [object ["id" .= identity, "value" .= object ["title" .= title]] | (identity,title) <- items]]

declarations :: [CollectionDecl]
declarations = [CollectionDecl "todos" "todos" []]

metadata :: SchemaMetadata
metadata = SchemaMetadata [] [] declarations

schema :: DataType
schema = Algebraic "Example.Root" [] [Constructor "Example.Root"
  [(Just "description",StringType),(Just "todos", ListType fact)]]
  where
    fact = Algebraic "Kyyn.Types.Fact.Fact" [payload]
      [Constructor "Kyyn.Types.Fact.Fact" [(Nothing,sdkFactIdType),(Nothing,payload)]]
    payload = Algebraic "Example.Todo" [] [Constructor "Example.Todo" [(Just "title",StringType)]]
