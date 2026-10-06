module Kyyn.Runtime.Judgement (exchangeJudgement) where

import Agentic.Questions (JudgeRequest, Answer)
import Kyyn.Runtime.Json (encodeWith)
import Kyyn.Runtime.JudgementWire (requestCodec, replyCodec)
import Kyyn.Runtime.Plugin (exchange)
import Kyyn.Runtime.Transport (Transport)

exchangeJudgement :: Transport -> Integer -> JudgeRequest -> IO (Either String [Answer])
exchangeJudgement transport identity request =
  exchange transport identity "judgement" "evaluate" (encodeWith requestCodec request) replyCodec
