-- Pure role contracts: distinct badges, duplicate/ambiguous roles and incompatible
-- field shapes.

{-# LANGUAGE OverloadedStrings #-}
module Main (main) where

import Control.Monad (unless)
import Data.Either (isLeft, isRight)
import Kyyn.Domain.Contract (checkContract)
import Kyyn.Types.Contract
import Kyyn.Types.SchemaMetadata

main :: IO ()
main = do
  let named name = NamedDescription (TypeIdentity "test" "Schema" name [])
      text = ScalarDescription (TypeIdentity "text" "Data.Text.Internal" "Text" []) TextScalar "Text" []
      fieldType name value = FieldDescription name "" value
      status = named "Status" (SumDescription
        [CaseDescription "Open" "" PositionalFields [], CaseDescription "Done" "" PositionalFields []])
      record = named "Todo" (RecordDescription "Todo" NamedFields
        [fieldType "name" text,fieldType "otherName" text,fieldType "status" status,fieldType "priority" status])
      roles = [RoleDecl "name" "Name" Title,RoleDecl "other-name" "Other name" Title,
        RoleDecl "status" "Status" Badge,RoleDecl "priority" "Priority" Badge]
      field name role = FieldRole "Schema.Todo" name role
      check assignments = checkContract record (SchemaMetadata roles assignments [])
      badges = [field "status" "status",field "priority" "priority"]
      assert label ok = unless ok (fail label)
  assert "distinct badge roles refused" (isRight (check badges))
  assert "title with multiple badges refused" (isRight (check (field "name" "name":badges)))
  assert "same badge role assigned twice" (isLeft (check [field "status" "status",field "priority" "status"]))
  assert "duplicate badge assignment accepted" (isLeft (check (badges ++ badges)))
  assert "two titles accepted" (isLeft (check [field "name" "name",field "otherName" "other-name"]))
  assert "invalid badge shape accepted" (isLeft (check [field "name" "status"]))
  assert "unknown badge role accepted" (isLeft (check [field "status" "missing"]))
  putStrLn "Distinct badge roles, singular titles and ambiguous assignment refusals passed."
