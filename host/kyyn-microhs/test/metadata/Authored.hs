module Authored where

import Kyyn.Types.SchemaMetadata
import Kyyn.Types.Fact

data Root = Root { todos :: [Fact Todo], people :: [Fact Todo] }
data Todo = Todo { title :: String, owner :: FactId }

schemaMetadata :: SchemaMetadata
schemaMetadata = SchemaMetadata
  [RoleDecl "task-name" ("Tasks in " ++ "München 🦋") Title,
   RoleDecl "date" "When" Timeline, RoleDecl "status" "State" Badge]
  [FieldRole "Authored.Todo" "title" "task-name"]
  (map (\name -> CollectionDecl name name [("owner", "people")]) ["todos", "people"])
