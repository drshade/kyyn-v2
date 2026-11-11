{ outputs = [] : List { name : Text, description : Text, query : Text, sink : { plugin : Text, instanceName : Text, method : Text } }, model = None { provider : < OpenAI | Anthropic >, model : Text, credential : Text }, views = [] : List { name : Text, description : Text, path : Text }, schemaType = "Schema.Root", schemaMetadata = "Annotations.metadata", validator = "Missing.validate"
, queries = [] : List { name : Text, description : Text, implementation : Text, inputType : Text, inputMetadata : Text, resultType : Text, resultMetadata : Text }
, tools = [] : List { name : Text, description : Text, implementation : Text, inputType : Text, resultType : Text }
}
