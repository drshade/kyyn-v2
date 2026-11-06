{ schemaType = "Schema.Root"
, schemaMetadata = "Schema.metadata"
, validator = "Schema.validate"
, queries =
  [ { name = "total", description = "Sum exact amounts"
    , implementation = "Queries.total"
    , inputType = "Queries.Args", inputMetadata = "Queries.emptyMetadata"
    , resultType = "Queries.Total", resultMetadata = "Queries.emptyMetadata"
    }
  ]
, tools = [] : List { name : Text, description : Text, implementation : Text, inputType : Text, resultType : Text }
}
