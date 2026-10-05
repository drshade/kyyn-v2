-- Jev provider mapping with explicit local credentials, sanitized errors and
-- cancellation via a recording transport; no live requests.

{-# LANGUAGE DataKinds, GADTs, LambdaCase, OverloadedStrings, OverloadedRecordDot #-}
module Main (main) where

import qualified Agentic.Jev as Jev
import Agentic.Questions
import Agentic.Runtime (SystemOne(..))
import qualified Agentic.Value as Value
import Control.Exception (AsyncException(UserInterrupt), throwIO, try, bracket)
import Control.Monad (unless, forM_)
import Data.Aeson (object, (.=))
import Data.Text (Text)
import Effectful (Eff, runEff)
import Effectful.Dispatch.Dynamic (interpret)
import Kyyn.Domain.Model
import Kyyn.Domain.Secret
import Kyyn.Plumbing.Capability.Judgement
import Kyyn.Plumbing.Capability.SecretStore
import Kyyn.Plumbing.Interpreter.Judgement
import qualified Network.HTTP.Client as Http
import System.Environment (lookupEnv, setEnv, unsetEnv)

main :: IO ()
main = do
  name <- either fail pure (secretName "JEV_TOKEN")
  let request = JudgeRequest (Value.String "private input")
        [AskYesNo "Reply?", AskChoice "Priority?" [("low",Nothing),("high",Just "Urgent")],
         AskScore "Severity?" [("low",Nothing),("high",Just "Urgent")]]
      answers = [YesNoAnswer 0.9, ChoiceAnswer "high" [("low",0.1),("high",0.9)] 0.8,
                 ScoreAnswer 0.75 [(0,0.25),(1,0.75)] 0.6]
      invoke credential factory = runEff . secrets credential . runJudgementWithProvider factory $ judge request
      connect settings = do
        check "explicit local key" (settings.key == Just "local-key")
        check "model" (settings.model == "jev-1.13.0")
        pure (SystemOne (\actual -> check "request unchanged" (actual == request) >> pure answers))
  result <- invoke (Just "local-key") connect
  check "answers unchanged" (result == Right answers)
  bracket (lookupEnv "JEV_TOKEN") (maybe (unsetEnv "JEV_TOKEN") (setEnv "JEV_TOKEN")) $ \_ -> do
    setEnv "JEV_TOKEN" "ambient-key"
    missing <- runEff . secrets Nothing . runJudgementIO $ judge request
    check "environment fallback" (missing == Left (MissingModelSecret name))
  forM_ ["","   "] $ \key -> do
    empty <- invoke (Just key) (\_ -> fail "Empty key reached provider")
    check "empty key" (empty == Left (EmptyModelSecret name))
  cancelled <- try @AsyncException (invoke (Just "local-key")
    (\_ -> pure (SystemOne (\_ -> throwIO UserInterrupt))))
  check "cancellation swallowed" (cancelled == Left UserInterrupt)
  network <- invoke (Just "local-key") (\_ -> throwIO (Http.InvalidUrlException "private" "private"))
  check "transport error" (network == Left ModelUnavailable)
  forM_ [(401,ModelAuthenticationRejected),(403,ModelAuthenticationRejected),(429,ModelRateLimited),
         (500,ModelUnavailable),(400,ModelRequestRejected)] $ \(status,expected) -> do
    refused <- invoke (Just "local-key") (\_ -> throwIO (Jev.HttpError status "private"))
    check "sanitized HTTP error" (refused == Left expected)
  malformed <- invoke (Just "local-key") (\_ -> throwIO (Jev.UnexpectedResponse "private"))
  check "sanitized malformed response" (malformed == Left InvalidModelResponse)
  let body = Jev.requestBody "jev-1.13.0" request
  check "upstream state preserved" (case body of Value.Object fs -> lookup "state" fs == Just (Value.String "private input"); _ -> False)
  let response = object ["answers" .= object
        ["q0" .= object ["noul" .= (0.9 :: Double)],
         "q1" .= object ["choice" .= ("high" :: String), "probabilities" .= object ["low" .= (0.1 :: Double),"high" .= (0.9 :: Double)], "confidence" .= (0.8 :: Double)],
         "q2" .= object ["score" .= (0.75 :: Double), "probabilities" .= object ["0" .= (0.25 :: Double),"1" .= (0.75 :: Double)], "confidence" .= (0.6 :: Double)]]]
  check "upstream answer mapping" (Jev.decodeResponse request response == Right answers)
  putStrLn "Jev SystemOne: upstream mapping, explicit local credentials, failures and cancellation passed."

secrets :: Maybe Text -> Eff (SecretStore : es) a -> Eff es a
secrets key = interpret $ \_ -> \case
  ReadSecret name -> pure (maybe (Left (SecretNotFound name)) Right key)
  _ -> error "Unexpected secret mutation"

check :: String -> Bool -> IO ()
check label condition = unless condition (fail label)
