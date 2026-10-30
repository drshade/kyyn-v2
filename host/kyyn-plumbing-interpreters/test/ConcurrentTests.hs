-- Native worker ownership: bounded overlap, ordered results, typed failures,
-- cancellation/join and use from a sequential higher-order callback. No network.
{-# LANGUAGE DataKinds, GADTs, TypeFamilies, OverloadedStrings #-}
module Main where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (async, cancel, waitCatch)
import Control.Concurrent.MVar
import qualified Control.Exception as Exception
import Control.Monad (forM_, unless, void)
import Data.IORef
import Effectful
import Effectful.Dispatch.Dynamic (interpret, localSeqUnlift, send)
import Kyyn.Domain.Failure
import Kyyn.Plumbing.Capability.ConcurrentExecution
import Kyyn.Plumbing.Capability.Failure
import Kyyn.Plumbing.Interpreter.ConcurrentExecution
import Kyyn.Plumbing.Interpreter.Failure
import System.Timeout (timeout)

data Callback :: Effect where
  Callback :: m a -> Callback m a
type instance DispatchOf Callback = Dynamic

sequentialCallback :: Eff (Callback : es) a -> Eff es a
sequentialCallback = interpret $ \env (Callback action) -> localSeqUnlift env (\unlift -> unlift action)

main :: IO ()
main = do
  forM_ [1,4,8] $ \width -> do
    active <- newIORef (0,0)
    gate <- newEmptyMVar
    let enter = atomicModifyIORef' active (\(n,p) -> ((n+1,max p (n+1)),n+1)) >>= \n ->
          if n == width then void (tryPutMVar gate ()) else pure ()
        leave = atomicModifyIORef' active (\(n,p) -> ((n-1,p),()))
        action n = liftIO $ Exception.bracket_ enter leave $ do
          readMVar gate
          threadDelay ((17-n)*1000)
          pure n
    result <- bounded $ runEff $ runFailure $ runConcurrentExecutionIO width $ sequentialCallback $
      send (Callback (concurrentlyBounded width (map action [1..16])))
    assert "results lost input order" (result == Right [1..16])
    counts <- readIORef active
    assert "width not bounded or workers not joined" (counts == (0,width))
  typed <- runEff $ runFailure $ runConcurrentExecutionIO 4 $
    concurrentlyBounded 4 [pure (Left "denied" :: Either String Int),pure (Right 2)]
  assert "typed Left became a worker exception" (typed == Right [Left "denied",Right 2])
  -- Keep one worker blocked while another fails; the failing call must join its sibling.
  started <- newEmptyMVar
  stopped <- newEmptyMVar
  let blocked = liftIO $ Exception.bracket_ (putMVar started ()) (putMVar stopped ()) (threadDelay 10000000)
      failed = liftIO (readMVar started) >> raiseFailure (RuntimeUnavailable (ProcessDiagnostic ReadOutput "fixture"))
  result <- bounded $ runEff $ runFailure $ runConcurrentExecutionIO 2 $ concurrentlyBounded 2 [blocked,failed]
  assert "fatal effect failure was lost" (case result of Left _ -> True; _ -> False)
  assert "failure returned before worker cleanup" =<< fmap (== Just ()) (tryReadMVar stopped)
  started2 <- newEmptyMVar
  stopped2 <- newEmptyMVar
  task <- async $ runEff $ runFailure $ runConcurrentExecutionIO 1 $ concurrentlyBounded 1
    [liftIO $ Exception.bracket_ (putMVar started2 ()) (putMVar stopped2 ()) (threadDelay 10000000)]
  bounded (takeMVar started2)
  bounded (cancel task)
  void (waitCatch task)
  assert "caller cancellation returned before join" =<< fmap (== Just ()) (tryReadMVar stopped2)
  putStrLn "Bounded concurrent effects, sequential callback, failure and cancellation passed."

bounded :: IO a -> IO a
bounded action = timeout 3000000 action >>= maybe (fail "Concurrent worker test timed out") pure
assert :: String -> Bool -> IO ()
assert message condition = unless condition (fail message)
