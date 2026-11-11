let Model = { provider : < OpenAI | Anthropic >, model : Text, credential : Text }

in { model = None Model
   , views = [] : List { name : Text, description : Text, path : Text }
   , schemaType = "Schema.Root"
   , schemaMetadata = "Schema.metadata"
   , validator = "Validate.validate"
   , queries = [] : List { name : Text, description : Text, implementation : Text, inputType : Text, inputMetadata : Text, resultType : Text, resultMetadata : Text }
   , tools = [] : List { name : Text, description : Text, implementation : Text, inputType : Text, resultType : Text }
   , outputs = [] : List { name : Text, description : Text, query : Text, sink : { plugin : Text, instanceName : Text, method : Text } }
   }
