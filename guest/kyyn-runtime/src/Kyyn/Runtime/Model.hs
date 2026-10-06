module Kyyn.Runtime.Model (exchangeModel) where

import qualified Agentic.Runtime as A
import Kyyn.Runtime.Json (encodeWith)
import Kyyn.Runtime.ModelWire (conversationCodec, replyCodec)
import Kyyn.Runtime.Plugin (exchange)
import Kyyn.Runtime.Transport (Transport)

exchangeModel :: Transport -> Integer -> A.Conversation -> IO (Either String A.Turn)
exchangeModel transport identity conversation = exchange transport identity "model" "turn"
  (encodeWith conversationCodec conversation) replyCodec
