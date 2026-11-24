{-# LANGUAGE OverloadedStrings #-}
module Kyyn.Porcelain.Protocol.PluginEvent (parseEventBatch) where
import Data.Aeson (Value, (.:), withObject)
import Data.Aeson.Types (Parser)
import qualified Data.Aeson.KeyMap as Keys
import Control.Monad (unless)
import Data.List (sort)
import Kyyn.Types.EventIdentity (EventIdentity(..))

parseEventBatch :: Value -> Parser ([(EventIdentity,Value)],Value)
parseEventBatch = withObject "event batch" $ \fields -> do
  unless (sort (Keys.keys fields) == ["arrivals","cursor"]) (fail "Expected arrivals and cursor")
  arrivals <- fields .: "arrivals" >>= traverse (withObject "event arrival" (\entry -> do
    unless (sort (Keys.keys entry) == ["identity","value"]) (fail "Expected identity and value")
    (,) <$> (EventIdentity <$> entry .: "identity") <*> entry .: "value"))
  (,) arrivals <$> fields .: "cursor"
