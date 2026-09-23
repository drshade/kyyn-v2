{ schemaType = "TodoSchemaV1.Root"
, schemaMetadata = "TodoSchemaV1.metadata"
, validator = "Validate.validate"
, queries = [] : List
    { name : Text, description : Text, implementation : Text
    , inputType : Text, inputMetadata : Text, resultType : Text, resultMetadata : Text
    }
, tools = [] : List
    { name : Text, description : Text, implementation : Text
    , inputType : Text, resultType : Text
    }
}
