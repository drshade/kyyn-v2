{-# LANGUAGE DataKinds, TypeFamilies #-}
module Kyyn.Plumbing.Capability.ProcessExecution
  ( ProcessExecution(..), ProcessPipes(..), ProcessSpec(..), ProcessExit(..)
  , withProcess, writeStdin, closeStdin, readStdout, awaitExit, collectStdout
  ) where

import Data.ByteString (ByteString)
import qualified Data.ByteString as Bytes
import Effectful (Effect, Eff, DispatchOf, Dispatch(..), (:>))
import Effectful.Dispatch.Dynamic (send)

data ProcessSpec = ProcessSpec
  { executable :: FilePath
  , arguments :: [String]
  , workingDirectory :: FilePath
  , environment :: [(String, String)]
  } deriving (Eq)

data ProcessExit = ProcessExit
  { exitCode :: Int
  , stderr :: ByteString
  } deriving (Eq, Show)

data ProcessExecution :: Effect where
  WithProcess :: ProcessSpec -> Eff (ProcessPipes : es) a -> ProcessExecution (Eff es) a

type instance DispatchOf ProcessExecution = Dynamic

data ProcessPipes :: Effect where
  WriteStdin :: ByteString -> ProcessPipes m ()
  CloseStdin :: ProcessPipes m ()
  ReadStdout :: ProcessPipes m (Maybe ByteString)
  AwaitExit :: ProcessPipes m ProcessExit

type instance DispatchOf ProcessPipes = Dynamic

withProcess :: ProcessExecution :> es => ProcessSpec -> Eff (ProcessPipes : es) a -> Eff es a
withProcess spec action = send (WithProcess spec action)

writeStdin :: ProcessPipes :> es => ByteString -> Eff es ()
writeStdin = send . WriteStdin

closeStdin :: ProcessPipes :> es => Eff es ()
closeStdin = send CloseStdin

readStdout :: ProcessPipes :> es => Eff es (Maybe ByteString)
readStdout = send ReadStdout

-- Drain stdout (or finish the protocol) before waiting: an unread pipe can fill.
awaitExit :: ProcessPipes :> es => Eff es ProcessExit
awaitExit = send AwaitExit

collectStdout :: ProcessPipes :> es => Eff es ByteString
collectStdout = go []
  where
    go chunks = readStdout >>= maybe (pure (Bytes.concat (reverse chunks))) (\chunk -> go (chunk : chunks))
