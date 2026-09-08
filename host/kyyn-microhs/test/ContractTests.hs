module ContractTests (contractTests) where

import Control.Monad (unless, forM_)
import Data.List (isInfixOf)
import Kyyn.Domain.DataType
import Kyyn.Domain.Diagnostic (Diagnostic(..))
import Kyyn.Plumbing.Capability.SchemaInspection.Contract
import Kyyn.Types.SchemaMetadata

contractTests :: IO ()
contractTests = do
  checked <- either (fail . show) pure (checkContract root metadata)
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
    ("duplicate affordance", root, SchemaMetadata roles (fields ++ fields) collections),
    ("missing root field", root, SchemaMetadata roles fields [CollectionDecl "todos" "absent" []]),
    ("duplicate collection names", root, SchemaMetadata roles fields (collections ++ collections)),
    ("unknown target collection", root, SchemaMetadata roles fields [CollectionDecl "todos" "todos" [("owner","absent")]]),
    ("missing reference field", root, SchemaMetadata roles fields [CollectionDecl "todos" "todos" [("absent","todos")]]),
    ("expected FactId", root, SchemaMetadata roles fields [CollectionDecl "todos" "todos" [("title","todos")]]),
    ("duplicate todos reference", root, SchemaMetadata roles fields [CollectionDecl "todos" "todos" [("owner","todos"),("owner","todos")]]),
    ("missing collection declaration", root, SchemaMetadata roles fields []),
    ("expected [Kyyn.Types.Fact.Fact", record "Model.Root" [("todos", ListType payload)], SchemaMetadata roles fields collections),
    ("duplicate Model.Todo fields", record "Model.Root" [("todos", factList (record "Model.Todo" [("title",StringType),("title",StringType)]))], metadata),
    ("constructor tags", record "Model.Root" [("x",Algebraic "Model.Bad" [] [Constructor "A.Same" [],Constructor "B.Same" []])], SchemaMetadata [] [] [])
    ] $ \(expected,t,m) -> case checkContract t m of
      Left [Diagnostic _ message] | expected `isInfixOf` message -> pure ()
      other -> fail (expected ++ ": " ++ show other)
  putStrLn "Contract coherence, reference projection and whole-contract identity checks passed."
  where
    record name fs = Algebraic name [] [Constructor name [(Just n,t) | (n,t) <- fs]]
    factId = Algebraic "Kyyn.Types.Fact.FactId" [] [Constructor "Kyyn.Types.Fact.FactId" [(Nothing,StringType)]]
    factList t = ListType (Algebraic "Kyyn.Types.Fact.Fact" [t]
      [Constructor "Kyyn.Types.Fact.Fact" [(Just "id",factId),(Just "value",t)]])
    payload = record "Model.Todo" [("title",OptionalType StringType),
      ("status",Algebraic "Model.Status" [] [Constructor "Model.Open" [],Constructor "Model.Done" []]),
      ("owner",OptionalType factId)]
    root = record "Model.Root" [("todos",factList payload)]
    metadata = SchemaMetadata [RoleDecl "title" "display name" Title,RoleDecl "badge" "status" Badge]
      [FieldRole "Model.Todo" "title" "title",FieldRole "Model.Todo" "status" "badge"]
      [CollectionDecl "todos" "todos" [("owner","todos")]]
