-- Pure role contracts: distinct badges, duplicate/ambiguous roles and incompatible
-- field shapes.

{-# LANGUAGE OverloadedStrings #-}
module Main (main) where

import Control.Monad (unless)
import Data.Either (isLeft, isRight)
import Kyyn.Domain.Contract (checkContract)
import Kyyn.Domain.DataType (DataType(..), Constructor(..))
import Kyyn.Types.SchemaMetadata

main :: IO ()
main = do
  let status = Algebraic "Schema.Status" [] [Constructor "Schema.Open" [],Constructor "Schema.Done" []]
      record = Algebraic "Schema.Todo" [] [Constructor "Schema.Todo"
        [(Just "name",StringType),(Just "otherName",StringType),(Just "status",status),(Just "priority",status)]]
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
