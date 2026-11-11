{ model = None { provider : < OpenAI | Anthropic >, model : Text, credential : Text }, views = [] : List { name : Text, description : Text, path : Text }, schemaType = "Main.Root"
, schemaMetadata = "Annotations.metadata"
, validator = "Main.validate"
, queries =
  [ { name = "total", description = "Sum exact amounts"
    , implementation = "Queries.total"
    , inputType = "Queries.Args", inputMetadata = "Annotations.emptyMetadata"
    , resultType = "Queries.Total", resultMetadata = "Annotations.emptyMetadata"
    }
  , { name = "count", description = "Count stored facts"
    , implementation = "OutputQueries.count"
    , inputType = "OutputQueries.Arguments", inputMetadata = "OutputQueries.metadata"
    , resultType = "OutputQueries.Result", resultMetadata = "OutputQueries.metadata"
    }
  ]
, tools = [ { name = "count", description = "Count through the captured method", implementation = "Tools.count", inputType = "Tools.Args", resultType = "Tools.Result" }
  , { name = "listCount", description = "Count through generic evidence", implementation = "Tools.listCount", inputType = "Tools.Args", resultType = "Tools.Result" }
  ]
, outputs = [ { name = "snapshot", description = "Publish stored fact count", query = "count"
    , sink = { plugin = "local-file", instanceName = "writer", method = "publish" } } ]
}
