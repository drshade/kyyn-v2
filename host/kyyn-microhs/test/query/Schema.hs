module Schema where

import Kyyn.Types.Fact
import Kyyn.Types.SchemaMetadata

data Root = Root { tasks :: [Fact Todo], people :: [Fact Person] }
data Todo = Todo { title :: String, owner :: FactId }
data Person = Person { name :: String }

type Input = String
type Result = Maybe Person

schemaMetadata :: SchemaMetadata
schemaMetadata = SchemaMetadata [] []
  [CollectionDecl "to-dos" "tasks" [("owner", "people")], CollectionDecl "people" "people" []]

inputMetadata :: SchemaMetadata
inputMetadata = SchemaMetadata [] [] []

resultMetadata :: SchemaMetadata
resultMetadata = SchemaMetadata [RoleDecl "label" "Person's name" Title]
  [FieldRole "Schema.Person" "name" "label"] []
