module Kyyn.Runtime.SchemaMetadata (encodeMetadata) where

import Kyyn.Types.SchemaMetadata
import Kyyn.Runtime.Json
import Text.JSON.Types (JSValue(JSArray))

encodeMetadata :: SchemaMetadata -> Either String String
encodeMetadata (SchemaMetadata rs fs cs) = printValue $ record
  [ ("roles", JSArray (map roleValue rs))
  , ("fieldRoles", JSArray (map fieldValue fs))
  , ("collections", JSArray (map collectionValue cs))
  ]
  where
    text = encodeWith stringCodec
    roleValue (RoleDecl n d a) = record
      [("name", text n), ("description", text d), ("affordance", tagged (show a) Nothing)]
    fieldValue (FieldRole t f r) = record
      [("recordType", text t), ("field", text f), ("role", text r)]
    collectionValue (CollectionDecl c f refs) = record
      [("collection", text c), ("rootField", text f),
       ("references", JSArray (map referenceValue refs))]
    referenceValue (f,c) = record [("field", text f), ("collection", text c)]
