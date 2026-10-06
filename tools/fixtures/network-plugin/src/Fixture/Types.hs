module Fixture.Types where
import Data.Text (Text)
data Config = Config { endpoint :: Text, secretKey :: Text, localPath :: FilePath }
type Payload = Text
