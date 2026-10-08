{-# LANGUAGE OverloadedStrings #-}
module Kyyn.Surfaces.Queries (queryListResult, queryDescriptionResult, queryValueResult) where

import Data.Aeson (object, (.=))
import qualified Data.Text as Text
import Kyyn.Domain.Query (QueryDescriptor(..), QueryResult(..))
import Kyyn.Domain.Value (CheckedValue(..))
import Kyyn.Surfaces.Result (Response, success)

queryListResult :: [QueryDescriptor] -> Response
queryListResult queries = success
  (object ["queries" .= [object ["name" .= name, "description" .= description] | QueryDescriptor name description _ _ <- queries]])
  (if null queries then ["No registered queries."] else [name ++ "  " ++ description | QueryDescriptor name description _ _ <- queries])

queryDescriptionResult :: QueryDescriptor -> Text.Text -> Text.Text -> Response
queryDescriptionResult (QueryDescriptor name description _ _) input output = success
  (object ["name" .= name, "description" .= description, "inputType" .= input, "resultType" .= output])
  [name ++ " — " ++ description, "Input: " ++ Text.unpack input, "Result: " ++ Text.unpack output]

queryValueResult :: QueryResult -> Text.Text -> Response
queryValueResult (QueryResult (CheckedValue _ value) _) rendered = success value [Text.unpack rendered]
