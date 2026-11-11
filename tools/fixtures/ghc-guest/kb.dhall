{ views = [] : List { name : Text, description : Text, path : Text }, schemaType = "Main.Root"
, schemaMetadata = "Annotations.metadata"
, validator = "Main.validate"
, queries =
  [ { name = "total", description = "Sum exact amounts"
    , implementation = "Queries.total"
    , inputType = "Queries.Args", inputMetadata = "Annotations.emptyMetadata"
    , resultType = "Queries.Total", resultMetadata = "Annotations.emptyMetadata"
    }
  ]
, tools = [] : List { name : Text, description : Text, implementation : Text, inputType : Text, resultType : Text }
}
