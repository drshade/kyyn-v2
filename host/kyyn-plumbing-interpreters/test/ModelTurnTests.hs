-- OpenAI/Anthropic native adapters with recording provider factories: explicit
-- SecretStore keys, missing/empty refusal before environment fallback, sanitized
-- failures and cancellation. No network or guest protocol test.

{-# LANGUAGE DataKinds, GADTs, LambdaCase, OverloadedStrings, OverloadedRecordDot #-}
module Main (main) where

import Agentic.Core (Instruction(..))
import Agentic.Runtime (Conversation(..), Turn(..), Raw(..), Action(..), SystemTwo(..))
import Agentic.Schema (schemaOf, Shape(SString))
import qualified Agentic.Value as Value
import qualified Agentic.OpenAI as OpenAI
import qualified Agentic.Anthropic as Anthropic
import Control.Exception (AsyncException(UserInterrupt), throwIO, try, bracket)
import Control.Monad (unless, forM_)
import Data.IORef (newIORef, modifyIORef', readIORef)
import Data.Text (Text)
import Effectful (Eff, IOE, runEff)
import Effectful.Dispatch.Dynamic (interpret)
import Kyyn.Domain.Model
import Kyyn.Domain.Secret
import Kyyn.Plumbing.Capability.ModelTurn
import Kyyn.Plumbing.Capability.SecretStore
import Kyyn.Plumbing.Interpreter.ModelTurn
import qualified Network.HTTP.Client as Http
import System.Environment (lookupEnv, setEnv, unsetEnv)

main :: IO ()
main = do
  selected <- either fail pure (secretName "MODEL_KEY")
  count <- newIORef (0 :: Int)
  let schema = schemaOf (SString Nothing)
      conversation = Conversation [] (Instruction "Draft") (Value.String "input") schema [] schema []
      reply = Turn (Raw (Value.String "provider-state")) (Respond (Value.String "result"))
      connect settings = do
        modifyIORef' count (+1)
        case settings of
          ConfiguredOpenAI cfg -> do
            check "OpenAI explicit key" (cfg.key == Just "local-key")
            check "OpenAI selected model" (cfg.model == "selected-model")
          ConfiguredAnthropic cfg -> do
            check "Anthropic explicit key" (cfg.key == Just "local-key")
            check "Anthropic selected model" (cfg.model == "selected-model")
        pure (SystemTwo (\actual -> check "conversation changed" (actual == conversation) >> pure reply))
      invoke key provider factory = runEff . secrets key . runModelTurnWithProvider factory $
        takeModelTurn (ModelConfiguration provider "selected-model" selected) conversation
  forM_ [OpenAI,Anthropic] $ \provider -> do
    result <- invoke (Just "local-key") provider connect
    check "turn changed" (result == Right reply)
    withEnvironment "OPENAI_API_KEY" "ambient-key" $ withEnvironment "ANTHROPIC_API_KEY" "ambient-key" $ do
      missing <- runEff . secrets Nothing . runModelTurnIO $
        takeModelTurn (ModelConfiguration provider "selected-model" selected) conversation
      check "environment fallback used" (missing == Left (MissingModelSecret selected))
    forM_ ["","   "] $ \empty -> do
      emptyResult <- invoke (Just empty) provider (\_ -> fail "Empty secret reached provider")
      check "empty key" (emptyResult == Left (EmptyModelSecret selected))
    invalid <- runEff . noSecrets . runModelTurnWithProvider (\_ -> fail "Invalid model reached provider") $
      takeModelTurn (ModelConfiguration provider " " selected) conversation
    check "invalid configuration" (invalid == Left InvalidModelConfiguration)
    cancelled <- try @AsyncException (invoke (Just "local-key") provider
      (\_ -> pure (SystemTwo (\_ -> throwIO UserInterrupt))))
    check "cancellation swallowed" (cancelled == Left UserInterrupt)
    network <- invoke (Just "local-key") provider
      (\_ -> throwIO (Http.InvalidUrlException "private-key" "private-body"))
    check "transport error leaked" (network == Left ModelUnavailable)
  calls <- readIORef count
  check "unexpected successful calls" (calls == 2)
  forM_ [(401,ModelAuthenticationRejected),(403,ModelAuthenticationRejected),(429,ModelRateLimited),
         (500,ModelUnavailable),(400,ModelRequestRejected)] $ \(status,expected) -> do
    a <- invoke (Just "local-key") OpenAI (\_ -> throwIO (OpenAI.HttpError status "private-key"))
    b <- invoke (Just "local-key") Anthropic (\_ -> throwIO (Anthropic.HttpError status "private-key"))
    check "provider status mapping" (a == Left expected && b == Left expected)
  forM_ [(OpenAI.Refused "private",ModelRefused),(OpenAI.Truncated,ModelIncomplete),
         (OpenAI.Incomplete "private",ModelIncomplete),(OpenAI.UnexpectedResponse "private",InvalidModelResponse)] $ \(err,expected) -> do
    result <- invoke (Just "local-key") OpenAI (\_ -> pure (SystemTwo (\_ -> throwIO err)))
    check "OpenAI error leaked" (result == Left expected)
  forM_ [(Anthropic.Refused (Just "private"),ModelRefused),(Anthropic.Truncated,ModelIncomplete),
         (Anthropic.UnexpectedStop "private",ModelIncomplete),(Anthropic.UnexpectedResponse "private",InvalidModelResponse)] $ \(err,expected) -> do
    result <- invoke (Just "local-key") Anthropic (\_ -> pure (SystemTwo (\_ -> throwIO err)))
    check "Anthropic error leaked" (result == Left expected)
  putStrLn "Both model providers: explicit checkout-local keys, no environment fallback, sanitized errors and cancellation passed."

secrets :: Maybe Text -> Eff (SecretStore : es) a -> Eff es a
secrets key = interpret $ \_ -> \case
  ReadSecret name -> pure (maybe (Left (SecretNotFound name)) Right key)
  _ -> error "Unexpected secret mutation"

noSecrets :: Eff (SecretStore : IOE : '[]) a -> Eff (IOE : '[]) a
noSecrets = interpret $ \_ _ -> error "Invalid configuration read a secret"

withEnvironment :: String -> String -> IO a -> IO a
withEnvironment name value action = bracket (lookupEnv name) restore (\_ -> setEnv name value >> action)
  where restore = maybe (unsetEnv name) (setEnv name)

check :: String -> Bool -> IO ()
check message condition = unless condition (fail message)
