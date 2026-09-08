module Authored where

import Kyyn.Types.SchemaMetadata

data Root = Root { todos :: [Todo] }
data Todo = Todo { title :: String }

schemaMetadata :: SchemaMetadata
schemaMetadata = SchemaMetadata
  [RoleDecl "task-name" ("Tasks in " ++ "München 🦋") Title,
   RoleDecl "date" "When" Timeline, RoleDecl "status" "State" Badge]
  [FieldRole "Authored.Todo" "title" "task-name"]
  (map (\name -> CollectionDecl name name [("owner", "people")]) ["todos", "people"])
