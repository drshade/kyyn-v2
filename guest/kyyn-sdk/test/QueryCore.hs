{-# LANGUAGE GADTs, OverloadedStrings #-}
module QueryCore (main) where

import Kyyn.Types.Fact
import Kyyn.Types.Program
import qualified Kyyn.Types.Query as SDK

data Todo = Todo String FactId
data Person = Person String
data Root = Root [Fact Todo] [Fact Person]

type Query a = SDK.Query Root a

todos :: SDK.CollectionBinding Root Todo
todos = SDK.CollectionBinding "todos" (\(Root values _) -> values)

people :: SDK.CollectionBinding Root Person
people = SDK.CollectionBinding "people" (\(Root _ values) -> values)

ownerName :: Query (Maybe String)
ownerName = do
  tasks <- SDK.readCollection todos
  case tasks of
    [] -> pure Nothing
    Fact _ (Todo _ owner):_ -> do
      person <- SDK.readFact people owner
      pure (case person of Just (Fact _ (Person name)) -> Just name; Nothing -> Nothing)

main :: IO ()
main = do
  let root = Root [Fact (FactId "todo-001") (Todo "Review" (FactId "person-001"))]
        [Fact (FactId "person-001") (Person "Ada")]
      SDK.Query program = ownerName
      expectedTrace = [SDK.CollectionRead "todos", SDK.FactRead "people" (FactId "person-001")]
      SDK.Query missing = SDK.readFact people (FactId "absent") >> SDK.readCollection todos >> pure True
  if SDK.runLocally root program /= (Just "Ada", expectedTrace) then fail "Dependent typed reads or trace failed" else pure ()
  if SDK.runLocally (Root [] []) program /= (Nothing, [SDK.CollectionRead "todos"]) then fail "Wrong snapshot or branch trace" else pure ()
  if SDK.runLocally root missing /= (True, [SDK.FactRead "people" (FactId "absent"), SDK.CollectionRead "todos"])
    then fail "Missing-fact trace failed" else pure ()
  if interpretProgram (\_ -> Nothing) (Pure (42 :: Integer)) /= Just 42 then fail "Program fold failed" else pure ()
  putStrLn "Typed snapshot requests, dependent continuations and read traces passed."
