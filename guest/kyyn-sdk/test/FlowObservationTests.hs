{-# LANGUAGE GADTs, OverloadedRecordDot #-}
-- Exercise the actual Program/ExceptT stack and observation transport without
-- providers. IO exceptions during Program interpretation remain unobservable.
module FlowObservationTests (check, guest) where

import qualified Agentic as A
import Control.Monad (unless, when)
import Control.Monad.Trans.Class (lift)
import Control.Monad.Trans.Except (ExceptT, runExceptT, throwE)
import Data.IORef
import Kyyn.Runtime.Flow (programScope, exchangeObservation)
import Kyyn.Runtime.Transport (withTransport)
import Kyyn.Types.Program (Program, request, interpretProgram)
import Kyyn.Types.Plugin (FetchError(..))
import qualified Data.Text as Text

data Capture a where
  Capture :: A.Summary -> Capture ()

type Step = ExceptT FetchError (Program Capture)

runtime :: A.Runtime Step
runtime = (A.runtimeWith (throwE . FetchError . Text.pack . show))
  { A.scope = A.exceptTScope programScope
  , A.observe = \event -> lift (request (Capture
      (A.summarise (event { A.payload = error "observation forced discarded payload" }))))
  }

record :: A.Runtime Step -> A.Agentic Step () a -> IO (Either FetchError a, [A.Summary])
record rt flow = do
  recorded <- newIORef []
  result <- interpretProgram (\(Capture summary) -> modifyIORef' recorded (summary:))
    (runExceptT (A.interpret rt flow ()))
  events <- reverse <$> readIORef recorded
  -- Force the public metadata encoding, including the lazy-payload regression.
  length (show (map A.summaryValue events)) `seq` pure ()
  pure (result,events)

check :: IO ()
check = do
  (success,events) <- record runtime (A.act (const (pure (error "lazy result" :: Int))))
  case success of Right _ -> pure (); Left _ -> fail "Successful flow failed"
  unless (map (.happened) events == [A.Entered Nothing,A.Entered Nothing,A.Returned A.Completed,A.Returned A.Completed])
    (fail "Incorrect successful scope trace")
  let primary = FetchError "body failed"
      failed :: A.Agentic Step () ()
      failed = A.act (const (throwE primary)) `A.named` "failing step"
  (result,failures) <- record runtime failed
  unless (result == Left primary && map (.happened) failures == replicate 3 (A.Entered Nothing) ++ replicate 3 A.Failed)
    (fail "ExceptT failure was not observed at each scope")
  unless (map (.occurrence) (drop 3 failures) == reverse (map (.occurrence) (take 3 failures)))
    (fail "Failure terminals do not match entered occurrences")
  (missing,missingEvents) <- record runtime (A.draft @Int @() "no model")
  unless (missing == Left (FetchError "NoSystemTwo") && any ((== A.Failed) . (.happened)) missingEvents)
    (fail "Runtime FlowError was not recorded")
  let notify phase event = do
        runtime.observe event
        when (event.happened == phase) (throwE (FetchError "observer failed"))
  (original,_) <- record (runtime { A.observe = notify A.Failed }) failed
  unless (original == Left primary) (fail "Observer replaced original short circuit")
  (entryFailure,entryEvents) <- record (runtime { A.observe = notify (A.Entered Nothing) })
    (A.act (const (error "entry failure must prevent body")) :: A.Agentic Step () ())
  unless (entryFailure == Left (FetchError "observer failed") && length entryEvents == 1)
    (fail "Entry failure produced a body or a terminal")
  (returnFailure,returnEvents) <- record (runtime { A.observe = notify (A.Returned A.Completed) })
    (A.act (const (pure ())) :: A.Agentic Step () ())
  unless (returnFailure == Left (FetchError "observer failed") &&
    map (.happened) returnEvents == [A.Entered Nothing,A.Entered Nothing,A.Returned A.Completed,A.Failed])
    (fail "Return notification failure invented a second child terminal")
  putStrLn "Program/ExceptT observation scopes preserve failures, ancestry and payload laziness."

guest :: IO ()
guest = do
  (_,events) <- record runtime (A.arr id :: A.Agentic Step () ())
  case events of
    first:_ -> withTransport $ \transport -> exchangeObservation transport 1 first
    [] -> fail "Missing root observation"
