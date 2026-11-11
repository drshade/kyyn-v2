-- Hermetic atomic report archive: heterogeneous changed values retain inferred
-- types, including unused empty/None annotations, without an old Root contract.
{-# LANGUAGE OverloadedStrings #-}
module Main (main) where
import Control.Monad (unless)
import Data.Aeson (object, (.=), Value(..))
import qualified Data.ByteString as Bytes
import Data.Either (isLeft)
import Effectful (runPureEff)
import Kyyn.Domain.Contract (checkContract, checkRootLayout)
import Kyyn.Domain.Evolution (evolutionId)
import Kyyn.Domain.DataType (Shape(..), ScalarKind(..))
import Kyyn.Domain.StoredSnapshot
import Kyyn.Domain.SnapshotReport
import Kyyn.Domain.Recipe (RecipeDefinition(..))
import qualified Kyyn.Types.Contract as D
import Kyyn.Types.SchemaMetadata (SchemaMetadata(..))
import Kyyn.Types.Evolution (Rationale(..))
import Kyyn.Types.Fact (FactId(..))
import Kyyn.Plumbing.Interpreter.DhallHandling (runDhallHandling)
import Kyyn.Plumbing.Protocol.SnapshotArchive

main :: IO ()
main = do
  target <- right (checkContract (D.NamedDescription (D.TypeIdentity "fixture" "Schema" "Root" [])
    (D.RecordDescription "Root" D.NamedFields [])) (SchemaMetadata [] [] []) >>= checkRootLayout)
  identity <- right (evolutionId "000001-archive")
  let text = Scalar TextScalar
      old = RecordedValue (Record [("id",text),("value",Scalar IntegerScalar)])
        (object ["id" .= String "one","value" .= String "7"])
      new = RecordedValue (Record [("id",text),("value",Record [("amount",Scalar IntegerScalar),("note",text)])])
        (object ["id" .= String "one","value" .= object ["amount" .= String "7","note" .= String "migrated"]])
      none shape = RecordedValue (Optional shape) (object ["tag" .= String "None"])
      state = RecordedValue (Record [("seen",List text)]) (object ["seen" .= ([] :: [String])])
      reason = Rationale "Archive migration" []
      steps = [SnapshotStep Authored reason
        [SnapshotFactChange "items" (FactId "one") (Just old) (Just new),
         SnapshotFieldChange "optional" (Just (none text)) (Just (none (Scalar BoolScalar))),
         SnapshotRecipeChange (FactId "review") Nothing (Just (RecordedRecipe (OpenRecipe "Review" "State") state))],
        SnapshotStep TargetProjection reason [SnapshotMembershipChange "new" Nothing (Just [])]]
      encode = runPureEff . runDhallHandling . encodeSnapshotArchive identity target []
      decode = runPureEff . runDhallHandling . decodeSnapshotArchive
  bytes <- right (encode steps)
  (owner,contract,plugins,restored) <- right (decode bytes)
  assert "archive identity/target changed" (owner == identity && contract == target && null plugins)
  assert "stored shape/value report changed" (restored == steps)
  repeated <- right (encode restored)
  assert "archive bytes are nondeterministic" (bytes == repeated)
  empty <- right (encode [])
  (_,_,_,emptySteps) <- right (decode empty)
  assert "empty catalogue cannot roundtrip" (null emptySteps)
  assert "imported report accepted" (isLeft (decode "./external.dhall"))
  assert "truncated report accepted" (isLeft (decode (Bytes.take (Bytes.length bytes `div` 2) bytes)))
  assert "wrong report format accepted" (isLeft (decode "{ format = \"other\" }"))
  putStrLn "Structural report archives roundtrip deterministically without historical contracts"
assert :: String -> Bool -> IO ()
assert message condition = unless condition (fail message)
right :: Show e => Either e a -> IO a
right = either (fail . show) pure
