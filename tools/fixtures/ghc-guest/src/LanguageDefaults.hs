module LanguageDefaults (languageWorks) where

import Data.Text (Text)
import GHC.Generics (Generic)
import Kyyn.Schema (Contract)

data First = First { label :: Text } deriving stock Generic deriving anyclass Contract
data Second = Second { label :: Text } deriving stock Generic deriving anyclass Contract

-- The ordinary binding can share a field name only with NoFieldSelectors.
label :: Text
label = "ordinary binding"

readFirst :: First -> Text
readFirst First{..} = label

choose :: Second -> Text
choose value = if | value.label == "yes" -> "chosen" | otherwise -> "other"

present :: Maybe Text
present = id do pure "ready"

unwrap :: Maybe Text -> Text
unwrap = \case Just value -> value; Nothing -> "empty"

languageWorks :: Bool
languageWorks = label == "ordinary binding" && readFirst (First "first") == "first"
  && choose (Second "yes") == "chosen" && unwrap present == "ready"
  && multiline == "hello\nguest" && small 0 && small 1 && not (small 2)

multiline :: Text
multiline = """
  hello
  guest
  """

small :: Int -> Bool
small (0; 1) = True
small _ = False
