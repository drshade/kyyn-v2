{-# LANGUAGE OverloadedStrings #-}
module Kyyn.Surfaces.Tools (toolListResult, toolResult) where

import Data.Aeson (object, (.=))
import Data.Coerce (coerce)
import qualified Data.Text as Text
import Kyyn.Domain.Model (ModelConfiguration(..))
import Kyyn.Domain.Secret (secretNameText)
import Kyyn.Domain.Plugin (MethodName(..))
import Kyyn.Domain.Tool (ToolDescriptor(..))
import Kyyn.Surfaces.Result (Response, success)

toolListResult :: [ToolDescriptor] -> Response
toolListResult tools = success
  (object ["tools" .= [object ["name" .= (coerce name :: String),"description" .= description]
    | ToolDescriptor name description _ _ <- tools]])
  (if null tools then ["No registered tools."] else
    [coerce name ++ "  " ++ description | ToolDescriptor name description _ _ <- tools])

toolResult :: MethodName -> String -> Text.Text -> Text.Text -> Maybe ModelConfiguration -> Response
toolResult name description input output configuration = success
  (object ["name" .= (coerce name :: String),"description" .= description,
    "inputType" .= input,"resultType" .= output,"model" .= fmap modelValue configuration])
  [coerce name ++ " — " ++ description,"Input: " ++ Text.unpack input,"Result: " ++ Text.unpack output,
   maybe "Model: not configured (root/model.dhall)" modelText configuration]
  where
    modelValue (ModelConfiguration provider model credential) = object
      ["provider" .= show provider,"model" .= model,"credential" .= secretNameText credential]
    modelText (ModelConfiguration provider model credential) =
      "Model: " ++ show provider ++ "/" ++ model ++ " (secret: " ++ secretNameText credential ++ ")"
