module Kyyn.Plumbing.Protocol.Description (descriptionShape, metadataShape, descriptionValue, parseDescription) where

import Kyyn.Types.Contract (descriptionValue, parseDescription)
import qualified Kyyn.Domain.DataType as Shape

-- Dhall has no recursive data types. Store finite descriptions in dependency
-- order and require every reference to point to an earlier node.
descriptionShape :: Shape.Shape
descriptionShape = Shape.Record
  [("types",Shape.List (Shape.Record [("package",text),("module",text),("name",text),("arguments",Shape.List index)])),
   ("nodes",Shape.List (Shape.Union
     [("Scalar",Just (Shape.Record [("type",index),("kind",Shape.List text),("name",text),("parameters",Shape.List pair)])),
      ("Named",Just (Shape.Record [("type",index),("inner",index)])),
      ("Record",Just (Shape.Record [("name",text),("style",style),("fields",Shape.List field)])),
      ("Sum",Just (Shape.List (Shape.Record [("name",text),("doc",text),("style",style),("fields",Shape.List field)]))),
      ("List",Just index),("Optional",Just index),("Unit",Nothing),
      ("Checked",Just annotation),("Documented",Just annotation)]))]
  where
    text = Shape.Scalar Shape.TextScalar
    index = Shape.Scalar Shape.IntegerScalar
    style = Shape.Union [("Named",Nothing),("Positional",Nothing)]
    pair = Shape.Record [("name",text),("value",text)]
    field = Shape.Record [("name",text),("doc",text),("inner",index)]
    annotation = Shape.Record [("text",text),("inner",index)]

metadataShape :: Shape.Shape
metadataShape = Shape.Record
  [("roles",Shape.List (Shape.Record [("name",text),("description",text),("affordance",Shape.Union
    [("Title",Nothing),("Timeline",Nothing),("Badge",Nothing)])])),
   ("fields",Shape.List (Shape.Record [("type",text),("field",text),("role",text)])),
   ("collections",Shape.List (Shape.Record [("name",text),("field",text),
     ("references",Shape.List (Shape.Record [("field",text),("collection",text)]))]))]
  where text = Shape.Scalar Shape.TextScalar
