{-# LANGUAGE GADTs, OverloadedRecordDot, LambdaCase #-}
-- Consumer integration: Kyyn's real Program/ExceptT scope, wire codecs and
-- replayed values across fresh interpreters. No provider or production store.
module FlowWaitingTests (check) where

import qualified Agentic as A
import qualified Agentic.Codec as C
import qualified Agentic.Schema as S
import qualified Agentic.Journal as J
import qualified Agentic.Wait as W
import qualified Agentic.Value as V
import Control.Monad (unless)
import Control.Monad.Trans.Class (lift)
import Control.Monad.Trans.Except (ExceptT, runExceptT, throwE)
import Data.IORef
import qualified Data.List.NonEmpty as NE
import qualified Data.Text as Text
import Kyyn.Runtime.Flow (programScope)
import Kyyn.Runtime.ModelWire (valueCodec)
import qualified Kyyn.Runtime.Json as Wire
import Kyyn.Types.Plugin (FetchError(..))
import Kyyn.Types.Program (Program, request, interpretProgram)

data Calls a where
  Lookup :: V.Value -> Calls (Maybe V.Value)
  Save :: V.Value -> V.Value -> Calls ()
  Effect :: Calls ()
  Observe :: A.Summary -> Calls ()

type Step = ExceptT FetchError (Program Calls)
type Store = [(V.Value,V.Value)]

runtime :: A.Runtime Step
runtime = (A.runtimeWith (throwE . FetchError . Text.pack . show))
  { A.scope = A.exceptTScope programScope
  , A.observe = lift . request . Observe . A.summarise
  , A.journal = Just (J.Journal (J.JournalIdentity "kyyn-wait-test" "fixed") (pure ())
      (lift . request . Lookup) (\key value -> lift (request (Save key value))))
  }

integer :: C.Codec Integer
integer = C.primitive S.SInteger V.Integer $ \case
  V.Integer n -> Right n
  _ -> Left "Expected integer"

flow :: A.Agentic Step [Integer] [Integer]
flow = A.each (A.durablyWith integer integer (\_ n -> lift (request Effect) >> pure n)
  A.>>> A.awaitWith integer integer)

-- Round-trip every persisted value through the actual host/guest value codec.
wire :: V.Value -> IO V.Value
wire value = either fail pure
  (Wire.decodeWith valueCodec (Wire.encodeWith valueCodec value))

run :: Store -> Step a -> IO (Either FetchError a,Store,Int,[A.Summary])
run initial action = do
  saved <- newIORef initial
  effects <- newIORef 0
  events <- newIORef []
  result <- interpretProgram (\case
    Lookup key -> lookup key <$> readIORef saved
    Save key value -> do
      k <- wire key
      v <- wire value
      previous <- lookup k <$> readIORef saved
      case previous of
        Just old | old /= v -> fail "Conflicting immutable completion"
        _ -> modifyIORef' saved (\xs -> (k,v) : filter ((/= k) . fst) xs)
    Effect -> modifyIORef' effects (+1)
    Observe summary -> do
      _ <- wire (A.summaryValue summary)
      modifyIORef' events (summary:)) (runExceptT action)
  (,,,) result <$> readIORef saved <*> readIORef effects <*> (reverse <$> readIORef events)

assert :: String -> Bool -> IO ()
assert label ok = unless ok (fail label)

check :: IO ()
check = do
  (first,saved,count,events) <- run [] (A.resumable runtime flow [10,20])
  waits <- case first of
    Right (A.RunWaiting ws) -> pure (NE.toList ws)
    _ -> fail "Expected waiting frontier"
  assert "both independent waits reached" (length waits == 2 && count == 2)
  assert "suspension is observed, not failed" (any ((== A.Suspended) . (.happened)) events &&
    not (any ((== A.Failed) . (.happened)) events))
  assert "durable operations classify live work before suspension"
    (length [() | event <- events, event.happened == A.Executing (A.KeyedOperation A.DurableEffect)] == 2)
  assert "await misses do not execute an action"
    (not (any ((== A.Executing (A.KeyedOperation A.AwaitedReply)) . (.happened)) events))
  persisted <- traverse (\w -> wire (W.pendingWaitValue w) >>=
    either (fail . Text.unpack) pure . W.pendingWaitFromValue) waits
  case persisted of
    [one,two] -> do
      (bad,unchanged,noEffects,noEvents) <- run saved (A.fulfil runtime flow one (V.String "bad"))
      assert "invalid reply neither saves nor executes" (case bad of
        Right (Left _) -> unchanged == saved && noEffects == 0 && null noEvents
        _ -> False)
      (accepted,filled,_,_) <- run saved (A.fulfil runtime flow one (V.Integer 11))
      assert "reply accepted" (accepted == Right (Right ()))
      (partial,partialStore,again,_) <- run filled (A.resumable runtime flow [10,20])
      assert "partial fulfilment resumes without repeating effects" (again == 0 && case partial of
        Right (A.RunWaiting ws) -> NE.toList ws == [two]
        _ -> False)
      (_,complete,_,_) <- run partialStore (A.fulfil runtime flow two (V.Integer 22))
      (finished,_,repeated,restored) <- run complete (A.resumable runtime flow [10,20])
      assert "typed replies reach final result" (finished == Right (A.RunFinished [11,22]) && repeated == 0)
      assert "completed operations do not classify replay as live"
        (not (any (\event -> case event.happened of A.Executing _ -> True; _ -> False) restored))
      assert "restoration observations survive wire encoding" (any (\event -> case event.happened of A.Restored _ -> True; _ -> False) restored)
      (duplicate,duplicateStore,_,_) <- run complete (A.fulfil runtime flow one (V.Integer 11))
      assert "duplicate reply is idempotent" (duplicate == Right (Right ()) && duplicateStore == complete)
      (conflict,conflictStore,_,_) <- run complete (A.fulfil runtime flow one (V.Integer 12))
      assert "conflicting reply does not replace original" (case conflict of
        Right (Left _) -> conflictStore == complete
        _ -> False)
    _ -> fail "Unexpected waiting frontier"
  let failed = A.awaitWith integer integer A.&&& A.act (\_ -> throwE (FetchError "fixture failure"))
        :: A.Agentic Step Integer (Integer,Integer)
  (failure,_,_,failureEvents) <- run [] (A.resumable runtime failed 1)
  assert "short-circuit failure is not a waiting outcome" (failure == Left (FetchError "fixture failure") &&
    any ((== A.Failed) . (.happened)) failureEvents)
  (plain,_,_,_) <- run [] (A.interpret runtime (A.awaitWith integer integer) 1)
  assert "plain interpret uses FetchError for an unexpected wait" (case plain of Left _ -> True; _ -> False)
  putStrLn "Kyyn Program/ExceptT waiting, typed fulfilment, replay and wire observations passed."
