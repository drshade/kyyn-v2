module Fixture.Types where
data Config = Config { endpoint :: String, secretKey :: String, localPath :: String }
type Payload = String
