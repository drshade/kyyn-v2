module Main where

import Control.Monad (forM_, unless)
import System.Mem (performGC, performGCWithReduction)

main :: IO ()
main = do
  getLine >> putStrLn "discarded"
  forM_ [368219, 500000, 1000000, 1000000] $ \size -> do
    input <- getLine
    performGC
    performGCWithReduction
    unless (input == replicate size 'x') (fail "line contents differ")
  putStrLn "checked"
