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
, tools = [{ name = "draft", description = "Nested recorded model turns", implementation = "Tools.draft", inputType = "Tools.Input", resultType = "Tools.Output" }, { name = "assess", description = "Applicative recorded judgement", implementation = "Tools.assess", inputType = "Tools.Input", resultType = "Tools.Input" }]
}
