{-# LANGUAGE OverloadedStrings #-}
module Kyyn.Surfaces.Tools (toolListResult) where

import Data.Aeson (object, (.=))
import Data.Coerce (coerce)
import Kyyn.Domain.Plugin (MethodName(..))
import Kyyn.Domain.Tool (ToolDescriptor(..))
import Kyyn.Surfaces.Result (Response, success)

toolListResult :: [ToolDescriptor] -> Response
toolListResult tools = success
  (object ["tools" .= [object ["name" .= (coerce name :: String),"description" .= description]
    | ToolDescriptor name description _ _ <- tools]])
  (if null tools then ["No registered tools."] else
    [coerce name ++ "  " ++ description | ToolDescriptor name description _ _ <- tools])
