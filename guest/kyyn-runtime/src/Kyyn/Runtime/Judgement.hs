module Kyyn.Runtime.Judgement (exchangeJudgement) where

import Agentic.Questions (JudgeRequest, Answer)
import Kyyn.Runtime.Json (encodeWith)
import Kyyn.Runtime.JudgementWire (requestCodec, replyCodec)
import Kyyn.Runtime.Plugin (exchange)

exchangeJudgement :: Integer -> JudgeRequest -> IO (Either String [Answer])
exchangeJudgement identity request =
  exchange identity "judgement" "evaluate" (encodeWith requestCodec request) replyCodec
