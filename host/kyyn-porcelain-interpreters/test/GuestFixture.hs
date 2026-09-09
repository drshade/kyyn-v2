module GuestFixture (fixtureProgram, executeFixture) where

import Data.ByteString (ByteString)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import Effectful (Eff, (:>))
import Kyyn.Domain.CompiledProgram (CompiledProgram(..), BuildIdentity(..))
import Kyyn.Domain.Path (relativePath)
import Kyyn.Plumbing.Capability.ProcessExecution

fixtureProgram :: String -> CompiledProgram
fixtureProgram script = CompiledProgram (BuildIdentity "fixture" "fixture")
  (either error id (relativePath "fixture.comb"), Text.encodeUtf8 (Text.pack script))

executeFixture :: ProcessExecution :> es
  => FilePath -> CompiledProgram -> ByteString -> Eff es (ByteString, ProcessExit)
executeFixture shell (CompiledProgram _ (_,script)) input =
  withProcess (ProcessSpec shell ["-c", "read -r input; " ++ Text.unpack (Text.decodeUtf8 script)] "/tmp" []) $ do
    writeStdin input
    closeStdin
    output <- collectStdout
    status <- awaitExit
    pure (output,status)
