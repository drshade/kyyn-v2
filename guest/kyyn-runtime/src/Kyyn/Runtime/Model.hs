module Kyyn.Runtime.Model (exchangeModel) where

import qualified Agentic.Runtime as A
import Kyyn.Runtime.Json (encodeWith)
import Kyyn.Runtime.ModelWire (conversationCodec, replyCodec)
import Kyyn.Runtime.Plugin (exchange)

exchangeModel :: Integer -> A.Conversation -> IO (Either String A.Turn)
exchangeModel identity conversation = exchange identity "model" "turn"
  (encodeWith conversationCodec conversation) replyCodec
