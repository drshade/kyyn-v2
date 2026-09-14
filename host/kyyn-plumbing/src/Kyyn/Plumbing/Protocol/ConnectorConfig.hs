module Kyyn.Plumbing.Protocol.ConnectorConfig (instanceShape, decodeInstances) where

import Control.Monad (unless, forM_)
import Data.Aeson (Value, (.:), withArray, withObject)
import Data.Aeson.Types (parseEither)
import Data.Foldable (toList)
import Data.List (nub)
import Kyyn.Domain.DataType (Shape(..), ScalarKind(..))
import Kyyn.Plumbing.Capability.GuestCompilation.Types (bindingModule)

instanceShape :: [(String,Shape)] -> Shape
instanceShape connectors = List (Record [("name",Scalar TextScalar),("binding",Scalar TextScalar),
  ("connector",Union [(name,Just config) | (name,config) <- connectors])])

decodeInstances :: Value -> Either String [(String,String,String,Value)]
decodeInstances value = do
  instances <- parseEither (withArray "connector instances" (traverse instanceValue . toList)) value
  let names = [name | (name,_,_,_) <- instances]
  unless (length names == length (nub names)) (Left "Instance names must be unique within a plugin")
  forM_ instances $ \(name,binding,_,_) -> do
    unless (not (null name)) (Left "Instance name must not be empty")
    _ <- either (Left . ((name ++ ": binding: ") ++)) Right (bindingModule ("Kyyn.Connectors." ++ binding))
    unless (binding `notElem` ["case","class","data","default","deriving","do","else","foreign","if","import",
      "in","infix","infixl","infixr","instance","let","module","newtype","of","then","type","where","qualified","as","hiding"])
      (Left (name ++ ": binding must not be a Haskell keyword"))
  pure instances
  where
    instanceValue = withObject "connector instance" $ \fields -> do
      name <- fields .: "name"
      binding <- fields .: "binding"
      (kind,config) <- fields .: "connector" >>= withObject "selected connector" (\c -> (,) <$> c .: "tag" <*> c .: "value")
      pure (name,binding,kind,config)
