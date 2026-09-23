{-# LANGUAGE GADTs #-}
module CurationPersistenceTests (curationPersistenceTests, sampleCuration) where

import Control.Monad (unless)
import Data.Either (isLeft)
import qualified Data.ByteString.Char8 as Bytes
import Effectful (runPureEff)
import Effectful.Dispatch.Dynamic (interpret)
import Kyyn.Porcelain.Capability.Curation (resolveCuration)
import Kyyn.Porcelain.Capability.EvidenceStore (EvidenceStore(..))
import qualified Kyyn.Types.Curation as Declaration
import Kyyn.Domain.Diagnostic (Diagnostic(..))
import Kyyn.Domain.Contract (checkContract, contractId)
import Kyyn.Domain.Curation
import Kyyn.Types.Fact (Fact(..), FactId(..))
import Data.Coerce (coerce)
import Kyyn.Domain.DataType (DataType(StringType))
import Kyyn.Domain.Evidence
import Kyyn.Domain.Plugin (PackageIdentity(..), pluginName)
import Kyyn.Types.SchemaMetadata (SchemaMetadata(..))
import Kyyn.Plumbing.Interpreter.DhallHandling (runDhallHandling)
import Kyyn.Porcelain.Protocol.CurationPersistence
import Kyyn.Porcelain.Capability.RootStore (readRootDefinition)
import Kyyn.Porcelain.Interpreter.RootStore (runRootStore)
import Kyyn.Porcelain.Protocol.RecipePersistence
import Kyyn.Domain.FileTree (fileTree)
import Kyyn.Domain.Path (relativePath)

sampleCuration :: CurationRegister
sampleCuration = either error id (curationRegister entries)
  where
    contract = contractId (either (error . show) id (checkContract StringType (SchemaMetadata [] [] [])))
    producer = EvidenceProducer (PackageIdentity "source") contract
    instanceRef = ConnectorInstanceRef (either error id (pluginName "files")) "documents"
    entries = [(RecipeId "todos", instanceRef, producer,
      [(EvidenceId "z", EvidenceFingerprint "last"), (EvidenceId "a", EvidenceFingerprint "first")])]

curationPersistenceTests :: IO ()
curationPersistenceTests = do
  resolutionTests
  let encode value = runPureEff (runDhallHandling (encodeRegister value))
      decode bytes = runPureEff (runDhallHandling (decodeRegister bytes))
      right = either (fail . show) pure
  bytes <- right (encode sampleCuration)
  restored <- right (decode (Just bytes))
  unless (restored == sampleCuration) (fail "Curation round trip changed acknowledged state")
  unless (encode restored == Right bytes) (fail "Curation encoding is not canonical")
  reversed <- either fail pure (curationRegister
    [(recipe,instanceRef,producer,reverse items) | (recipe,instanceRef,producer,items) <- curationEntries sampleCuration])
  unless (encode reversed == Right bytes && reversed == sampleCuration) (fail "Entry order changed register identity or bytes")
  unless (decode Nothing == Right emptyCurationRegister) (fail "Absent register is not empty")
  unless (all (isLeft . decode . Just) ["./external.dhall", Bytes.pack "[{}]"])
    (fail "Invalid/importing register was accepted")
  unless (isLeft (curationRegister (curationEntries sampleCuration ++ curationEntries sampleCuration)))
    (fail "Duplicate recipe/instance register accepted")
  let readManifest extra = runPureEff . runDhallHandling . runRootStore . readRootDefinition $
        either error id (fileTree [(either error id (relativePath "kb.dhall"), Bytes.pack
          ("{ schemaType = \"Schema.Root\", schemaMetadata = \"Schema.metadata\", validator = \"Validate.validate\", " ++
           "queries = [] : List { name : Text, description : Text, implementation : Text, inputType : Text, inputMetadata : Text, resultType : Text, resultMetadata : Text }, " ++
           "tools = [] : List { name : Text, description : Text, implementation : Text, inputType : Text, resultType : Text }" ++ extra ++ " }"))])
      declaration = Fact (FactId "syncTodos") (Recipe "Inspect current evidence")
      encodeRecipeData value = runPureEff (runDhallHandling (encodeRecipes value))
      decodeRecipeData value = runPureEff (runDhallHandling (decodeRecipes value))
  _ <- right (readManifest "")
  unless (isLeft (readManifest ", recipes = [] : List { name : Text, instructions : Text }"))
    (fail "Obsolete manifest recipe field accepted")
  recipeBytes <- right (encodeRecipeData [declaration])
  unless (decodeRecipeData (Just recipeBytes) == Right [declaration]) (fail "Recipe data round trip failed")
  unless (decodeRecipeData Nothing == Right []) (fail "Absent recipe data is not empty")
  unless (all (isLeft . encodeRecipeData)
      [[declaration,declaration], [Fact (FactId "bad-name") (Recipe "x")]])
    (fail "Duplicate or invalid recipe IDs accepted")
  unless (all (isLeft . decodeRecipeData . Just)
      ["./external.dhall", "True", "[{ id = \"bad-name\", value = { instructions = \"x\" } }]"])
    (fail "Invalid recipe data accepted")
  putStrLn "Curation Dhall round trips, canonical order and absent/invalid material checks passed."

resolutionTests :: IO ()
resolutionTests = do
  let (recipe,instanceRef,producer,items) = case curationEntries sampleCuration of
        [entry] -> entry
        _ -> error "Expected one sample register entry"
      recipes = [Fact (FactId (coerce recipe)) (Recipe "Inspect evidence")]
      scope fetch = Declaration.EvidenceScope "files" "documents" fetch
      declaration values = Just (Declaration.Curation recipe values)
      run selected = runPureEff . interpret (\_ operation -> case operation of
        ResolveEvidenceCapture actual fetch -> pure $ if actual /= instanceRef
          then Left NotFetched
          else case fetch of
            FetchId "old" -> Right (EvidenceCapture (EvidenceSnapshotRef instanceRef producer fetch) items)
            FetchId "new" -> Right (EvidenceCapture (EvidenceSnapshotRef instanceRef producer fetch) [])
            _ -> Left CursorUnavailable
        _ -> error "Curation used a non-resolution evidence operation") $
          resolveCuration recipes selected emptyCurationRegister
      expected = curationRegister [(recipe,instanceRef,producer,[])]
      refused code result = case result of
        Left [Diagnostic _ actual _ _] -> actual == code
        _ -> False
  unless (run (declaration [Declaration.EntireBatch (scope "old")]) == Right sampleCuration)
    (fail "Scope resolution lost acknowledged identities")
  unless (run (declaration [Declaration.EntireBatch (scope "old"),
      Declaration.IndividualRecords (scope "new") (map fst items)]) == either (error . show) Right expected)
    (fail "Selective deletion or declaration ordering failed")
  unless (run (declaration [Declaration.EntireBatch (scope "new"),Declaration.EntireBatch (scope "old")]) == Right sampleCuration)
    (fail "Older declaration last did not win")
  unless (run Nothing == Right emptyCurationRegister) (fail "No curation changed progress")
  unless (refused "curation.recipe-unknown" (run (Just (Declaration.Curation (RecipeId "unknown") []))))
    (fail "Unknown recipe accepted")
  unless (refused "curation.scope-unavailable" (run (declaration [Declaration.EntireBatch (scope "missing")])))
    (fail "Missing scope was substituted")
