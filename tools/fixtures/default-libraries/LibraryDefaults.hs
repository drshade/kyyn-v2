module LibraryDefaults (librariesWork) where

import qualified Crypto.Hash.SHA256 as SHA256
import Control.Lens (set, view)
import Data.Generics.Product.Fields (field)
import GHC.Generics (Generic)
import qualified Data.Aeson as Json
import qualified Data.ByteString as Bytes
import qualified Data.Set as Set
import Data.Text (Text)
import Data.Time (addDays, fromGregorian)

data Sample = Sample { value :: Integer } deriving stock Generic

librariesWork :: Bool
librariesWork =
  Bytes.unpack (SHA256.hash "abc") ==
    [0xba,0x78,0x16,0xbf,0x8f,0x01,0xcf,0xea,0x41,0x41,0x40,0xde,0x5d,0xae,0x22,0x23,
     0xb0,0x03,0x61,0xa3,0x96,0x17,0x7a,0x9c,0xb4,0x10,0xff,0x61,0xf2,0x00,0x15,0xad]
  && view (field @"value") (set (field @"value") 2 (Sample 1)) == 2
  && Json.decode (Json.encode (["hello"] :: [Text])) == Just (["hello"] :: [Text])
  && Set.size (Set.fromList ([1,1,2] :: [Integer])) == 2
  && addDays 1 (fromGregorian 2024 2 28) == fromGregorian 2024 2 29
