{-# LANGUAGE OverloadedStrings #-}
module ContractTests (contractTests) where

import Control.Monad (unless, forM_)
import Data.List (isInfixOf)
import qualified Data.Text as Text
import Kyyn.Domain.DataType
import Kyyn.Domain.Diagnostic (Diagnostic(Diagnostic))
import Kyyn.Domain.Contract
import Kyyn.Types.SchemaMetadata

contractTests :: IO ()
contractTests = do
  empty <- either (fail . show) pure (checkContract
    (Algebraic "Empty.Root" [] [Constructor "Empty.Root" []]) (SchemaMetadata [] [] []) >>= checkRootLayout)
  unless (contractShape (rootSchema empty) == Record []) (fail "Empty root is not an empty record")
  unless (shapeOf sdkFactIdType == Right (Scalar TextScalar)) (fail "SDK FactId must project to text")
  unless (shapeOf (Algebraic "Model.FactId" [] [Constructor "Model.FactId" [(Nothing,StringType)]])
    == Right (Union [("FactId", Just (Scalar TextScalar))])) (fail "author type must not gain SDK scalar semantics by short name")
  checked <- either (fail . show) pure (checkContract root metadata)
  refined <- either (fail . show) pure (checkRootLayout checked)
  unless (rootSchema refined == checked && contractId (rootSchema refined) == contractId checked)
    (fail "Root refinement changed the contract or its identity")
  unregistered <- either (fail . show) pure (checkContract root (SchemaMetadata [] [] []))
  case checkRootLayout unregistered of
    Left [Diagnostic _ "schema.incoherent" message _] | "missing collection declaration" `isInfixOf` Text.unpack message -> pure ()
    result -> fail ("Unregistered persistent collection accepted: " ++ show result)
  forM_ [StringType, IntegerType, BoolType, ListType payload, OptionalType payload,
      Algebraic "Model.Choice" [] [Constructor "Model.Yes" [], Constructor "Model.No" []]] $ \valueType -> do
    valueContract <- either (fail . show) pure (checkContract valueType (SchemaMetadata [] [] []))
    unless (Right (contractShape valueContract) == shapeOf valueType) (fail "Value shape changed")
    case checkRootLayout valueContract of Left _ -> pure (); Right _ -> fail "Nonrecord accepted as a persistent root"
  listRoles <- either (fail . show) pure (checkContract (ListType payload)
    (SchemaMetadata [RoleDecl "title" "title" Title] [FieldRole "Model.Todo" "title" "title"] []))
  unless (Right (contractShape listRoles) == shapeOf (ListType payload)) (fail "Roles changed list shape")
  unless (metadataOf checked == metadata && rootType checked == root) (fail "contract lost its input")
  case collectionContracts checked of
    [CollectionContract "todos" "todos" _ (Record fs)] ->
      unless (lookup "owner" fs == Just (Optional (Reference "todos"))) (fail "reference annotation missing")
    other -> fail ("wrong collection shape: " ++ show other)
  let SchemaMetadata roles fields collections = metadata
      changed = SchemaMetadata (RoleDecl "title" "changed description" Title : drop 1 roles) fields collections
  changedContract <- either (fail . show) pure (checkContract root changed)
  unless (contractId checked /= contractId changedContract && contractShape checked == contractShape changedContract)
    (fail "role-only edit must change whole contract identity, without changing structure")
  unless (checkContract root metadata == Right checked) (fail "contract identity is not deterministic")
  forM_ [
    ("duplicate role", root, SchemaMetadata (roles ++ roles) fields collections),
    ("unknown role", root, SchemaMetadata roles [FieldRole "Model.Todo" "title" "missing"] collections),
    ("unknown record", root, SchemaMetadata roles [FieldRole "Missing" "title" "title"] collections),
    ("missing field", root, SchemaMetadata roles [FieldRole "Model.Todo" "absent" "title"] collections),
    ("incompatible Title", root, SchemaMetadata roles [FieldRole "Model.Todo" "status" "title"] collections),
    ("incompatible Badge", root, SchemaMetadata roles [FieldRole "Model.Todo" "title" "badge"] collections),
    ("incompatible Timeline", root, SchemaMetadata [RoleDecl "time" "date" Timeline] [FieldRole "Model.Todo" "title" "time"] collections),
    ("duplicate role assignments", root, SchemaMetadata roles (fields ++ fields) collections),
    ("missing root field", root, SchemaMetadata roles fields [CollectionDecl "todos" "absent" []]),
    ("duplicate collection names", root, SchemaMetadata roles fields (collections ++ collections)),
    ("unknown target collection", root, SchemaMetadata roles fields [CollectionDecl "todos" "todos" [("owner","absent")]]),
    ("missing reference field", root, SchemaMetadata roles fields [CollectionDecl "todos" "todos" [("absent","todos")]]),
    ("expected FactId", root, SchemaMetadata roles fields [CollectionDecl "todos" "todos" [("title","todos")]]),
    ("duplicate todos reference", root, SchemaMetadata roles fields [CollectionDecl "todos" "todos" [("owner","todos"),("owner","todos")]]),
    ("expected [Kyyn.Types.Fact.Fact", record "Model.Root" [("todos", ListType payload)], SchemaMetadata roles fields collections),
    ("duplicate Model.Todo fields", record "Model.Root" [("todos", factList (record "Model.Todo" [("title",StringType),("title",StringType)]))], metadata),
    ("constructor tags", record "Model.Root" [("x",Algebraic "Model.Bad" [] [Constructor "A.Same" [],Constructor "B.Same" []])], SchemaMetadata [] [] [])
    ] $ \(expected,t,m) -> case checkContract t m of
      Left [Diagnostic _ _ message _] | expected `isInfixOf` Text.unpack message -> pure ()
      other -> fail (expected ++ ": " ++ show other)
  putStrLn "Contract coherence, reference projection and whole-contract identity checks passed."
  where
    record name fs = Algebraic name [] [Constructor name [(Just n,t) | (n,t) <- fs]]
    factId = sdkFactIdType
    factList t = ListType (Algebraic "Kyyn.Types.Fact.Fact" [t]
      [Constructor "Kyyn.Types.Fact.Fact" [(Nothing,factId),(Nothing,t)]])
    payload = record "Model.Todo" [("title",OptionalType StringType),
      ("status",Algebraic "Model.Status" [] [Constructor "Model.Open" [],Constructor "Model.Done" []]),
      ("owner",OptionalType factId)]
    root = record "Model.Root" [("todos",factList payload)]
    metadata = SchemaMetadata [RoleDecl "title" "display name" Title,RoleDecl "badge" "status" Badge]
      [FieldRole "Model.Todo" "title" "title",FieldRole "Model.Todo" "status" "badge"]
      [CollectionDecl "todos" "todos" [("owner","todos")]]
