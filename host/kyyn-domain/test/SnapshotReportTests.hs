-- Observation continuity and derived changes over checked structural snapshots.
-- Transport validation and target projection itself are tested in their owners.
{-# LANGUAGE OverloadedStrings #-}
module Main (main) where
import Control.Monad (unless)
import Data.Either (isLeft)
import Data.Aeson (object, (.=))
import Kyyn.Domain.DataType
import Kyyn.Domain.StoredSnapshot
import Kyyn.Domain.SnapshotReport
import Kyyn.Types.Fact
import Kyyn.Types.Evolution

main :: IO ()
main = do
  let rationale = Rationale "Migration" []
      payload name = RecordedValue (Record [("id",Scalar TextScalar),("value",Scalar TextScalar)])
        (object ["id" .= name,"value" .= ("unchanged" :: String)])
      a = Fact (FactId "a") (payload ("a" :: String))
      b = Fact (FactId "b") (payload ("b" :: String))
      initial = StoredSnapshot [] [("people",[a,b])] []
      projected = StoredSnapshot [] [("people",[a,b]),("new",[])] []
      reordered = StoredSnapshot [] [("new",[]),("people",[b,a])] []
      projection = SnapshotObservation TargetProjection rationale initial projected
      authored = SnapshotObservation Authored rationale projected reordered
      check input target final steps = checkSnapshotContinuity rationale input target final steps
  reports <- right (check initial projected reordered [projection,authored])
  assert "empty collection addition not visible" (case reports of
    SnapshotStep TargetProjection _ changes : _ ->
      SnapshotMembershipChange "new" Nothing (Just []) `elem` changes
    _ -> False)
  assert "reordering produced payload edits" (case reports of
    [_,SnapshotStep Authored _ [SnapshotMembershipChange "people" (Just [FactId "a",FactId "b"]) (Just [FactId "b",FactId "a"])]] -> True
    _ -> False)
  assert "missing projection accepted" (isLeft (check initial projected initial []))
  assert "duplicate projection accepted" (isLeft (check initial projected projected [projection,projection]))
  assert "forged final value accepted" (isLeft (check initial projected initial [projection]))
  assert "discontinuous intermediate accepted" (isLeft (check initial projected reordered
    [projection,SnapshotObservation Authored rationale initial reordered]))
  assert "forged projection accepted" (isLeft (check initial initial projected [projection]))
  assert "forged explanation accepted" (isLeft (check initial projected projected
    [SnapshotObservation TargetProjection (Rationale "invented" []) initial projected]))
  let empty = object ["tag" .= ("None" :: String)]
      first = StoredSnapshot [("optional",RecordedValue (Optional (Scalar TextScalar)) empty)] [] []
      second = StoredSnapshot [("optional",RecordedValue (Optional (Scalar BoolScalar)) empty)] [] []
  assert "stored type change hidden behind equal value" (case snapshotChanges first second of
    [SnapshotFieldChange "optional" _ _] -> True
    _ -> False)
  assert "map order incorrectly significant" (equivalentSnapshots projected
    (StoredSnapshot [] [("new",[]),("people",[a,b])] []))
  let renamed = StoredSnapshot [] [("people",[Fact (FactId "new-id") (payload ("new-id" :: String)),b])] []
      changed = snapshotChanges initial renamed
  assert "identity remap hid removal" (SnapshotFactChange "people" (FactId "a") (Just (payload ("a" :: String))) Nothing `elem` changed)
  assert "identity remap hid addition" (SnapshotFactChange "people" (FactId "new-id") Nothing (Just (payload ("new-id" :: String))) `elem` changed)
  putStrLn "Structural observation/report checks passed"
assert :: String -> Bool -> IO ()
assert message condition = unless condition (fail message)
right :: Show e => Either e a -> IO a
right = either (fail . show) pure
