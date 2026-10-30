-- Scheduler contract checked under both compilers: fairness, nesting, ordered
-- results, fail-fast boundaries and handled intermediate failures. No provider.
{-# LANGUAGE GADTs #-}
module KyynPluginEntry where

import Control.Monad (forM_, unless, replicateM)
import System.Environment (getArgs)
import Data.IORef
import qualified Data.ByteString as Bytes
import Kyyn.Types.Program
import Kyyn.Runtime.Concurrent
import Kyyn.Runtime.Json

data ReadInt a where
  ReadInt :: Integer -> ReadInt Integer

readInt :: Integer -> Program ReadInt Integer
readInt n = request (ReadInt n)

handle :: ReadInt a -> Exchange a
handle (ReadInt n) = metadataExchange "fixture" "read" (encodeWith integerCodec n) integerCodec

recorded :: Int -> Program ReadInt a -> IO (a,[(Bool,[Integer],[Integer])])
recorded width program = do
  rounds <- newIORef []
  let respond grouped calls = do
        values <- mapM (\(_,WireRequest _ _ args _) -> either fail pure (decodeWith integerCodec args)) calls
        modifyIORef rounds ((grouped,map fst calls,values):)
        pure [(encodeWith integerCodec value,Bytes.empty) | value <- values]
  result <- runConcurrent width handle respond program
  trace <- reverse <$> readIORef rounds
  assert "round exceeds width" (all (\(_,ids,_) -> length ids <= width) trace)
  let ids = concat [values | (_,values,_) <- trace]
  assert "noncontiguous invocation IDs" (ids == [1..toInteger (length ids)])
  pure (result,trace)

main :: IO ()
main = do
  args <- getArgs
  if args == ["--benchmark"] then benchmark else contracts

contracts :: IO ()
contracts = do
  forM_ [1,4,8] $ \width -> do
    let branch n = readInt n >>= \a -> readInt (100+a)
        program = concurrently [branch n | n <- [1..11]]
    (values,trace) <- recorded width program
    serial <- interpretProgram (\(ReadInt n) -> pure n) program
    assert "concurrent success differs from sequential interpretation" (values == serial)
    assert "group used unguarded singleton request" (all (\(batch,_,_) -> batch) trace)
    (nested,nestedTrace) <- recorded width $ concurrently
      [sum <$> concurrently [branch 1,branch 2],branch 3]
    assert "nested results not in input order" (nested == [203,103])
    assert "nested groups escaped batch path" (all (\(batch,_,_) -> batch) nestedTrace)
    (empty,emptyTrace) <- recorded width (concurrently ([] :: [Program ReadInt Integer]))
    assert "empty group dispatched a request" (null empty && null emptyTrace)
    (_,singleton) <- recorded width (concurrently [readInt 7])
    assert "singleton group lost its batch guard" (singleton == [(True,[1],[7])])
    (_,ordinary) <- recorded width (readInt 7)
    assert "ordinary request changed framing" (ordinary == [(False,[1],[7])])
    (failure,noCalls) <- recorded width (concurrentlyE [pure (Left "pure"),Right <$> readInt 1])
    assert "completed failing child dispatched its sibling" (failure == Left "pure" && null noCalls)
    -- The parent can handle a nested group's final Left and continue.
    (handled,_) <- recorded width $ concurrently [do
      result <- concurrentlyE [readInt 1 >> pure (Left "expected" :: Either String Integer)]
      case result of Left _ -> readInt 8; Right _ -> readInt 9]
    assert "nested error bypassed parent continuation" (handled == [8])
  (_,fair) <- recorded 1 $ concurrently [readInt 1 >> readInt 11,readInt 2 >> readInt 12,readInt 3 >> readInt 13]
  assert "width-one group starved later branches" (concat [values | (_,_,values) <- fair] == [1,2,3,11,12,13])
  (failure,trace) <- recorded 4 $ concurrentlyE
    [readInt 1 >> pure (Left "first" :: Either String Integer),readInt 2 >> pure (Left "second"),
     readInt 3 >> readInt 30 >> pure (Right 3),readInt 4 >> pure (Right 4),Right <$> readInt 5]
  assert "wrong failing child selected at boundary" (failure == Left "first")
  assert "failed group continued after its complete round" (trace == [(True,[1,2,3,4],[1,2,3,4])])
  (later,laterTrace) <- recorded 1 $ concurrentlyE
    [readInt 1 >> readInt 10 >> pure (Right 1),readInt 2 >> pure (Left "later" :: Either String Integer)]
  assert "later completed error waited for an earlier unfinished branch" (later == Left "later" && concat [v | (_,_,v) <- laterTrace] == [1,2])
  putStrLn "Concurrent scheduler contract passed."

assert :: String -> Bool -> IO ()
assert message condition = unless condition (fail message)

benchmark :: IO ()
benchmark = do
  (result,trace) <- recorded 4 $ concurrently [sum <$> replicateM 10 (readInt n) | n <- [1..500]]
  assert "synthetic result differs" (result == [10*n | n <- [1..500]])
  assert "synthetic count differs" (sum [length ids | (_,ids,_) <- trace] == 5000)
  putStrLn "500 independent workflows, 5000 requests, width 4."
