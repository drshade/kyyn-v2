{ schemaType = "Main.Root"
, schemaMetadata = "Annotations.metadata"
, validator = "Main.validate"
, queries =
  [ { name = "total", description = "Sum exact amounts"
    , implementation = "Queries.total"
    , inputType = "Queries.Args", inputMetadata = "Annotations.emptyMetadata"
    , resultType = "Queries.Total", resultMetadata = "Annotations.emptyMetadata"
    }
  ]
, tools = [ { name = "count", description = "Count through the captured method", implementation = "Tools.count", inputType = "Tools.Args", resultType = "Tools.Result" }
  , { name = "listCount", description = "Count through generic evidence", implementation = "Tools.listCount", inputType = "Tools.Args", resultType = "Tools.Result" }
  ]
}
