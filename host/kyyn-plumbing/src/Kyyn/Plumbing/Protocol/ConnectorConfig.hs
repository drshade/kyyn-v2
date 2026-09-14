module Kyyn.Plumbing.Protocol.ConnectorConfig (decodeInstances) where

import Control.Monad (unless, forM)
import Data.Aeson (Value, (.:), withArray, withObject)
import Data.Aeson.Types (parseEither)
import Data.Foldable (toList)
import Data.List (nub)
import Kyyn.Domain.Plugin (ConnectorName(..), BindingName(..), ConnectorTypeName(..), connectorName, bindingName, connectorTypeName)

decodeInstances :: Value -> Either String [(ConnectorName,BindingName,ConnectorTypeName,Value)]
decodeInstances value = do
  instances <- parseEither (withArray "connector instances" (traverse instanceValue . toList)) value
  let names = [name | (name,_,_,_) <- instances]
  unless (length names == length (nub names)) (Left "Instance names must be unique within a plugin")
  forM instances $ \(name,binding,kind,config) -> do
    checkedName <- connectorName name
    checkedBinding <- either (Left . ((name ++ ": ") ++)) Right (bindingName binding)
    checkedKind <- connectorTypeName kind
    pure (checkedName,checkedBinding,checkedKind,config)
  where
    instanceValue = withObject "connector instance" $ \fields -> do
      name <- fields .: "name"
      binding <- fields .: "binding"
      (kind,config) <- fields .: "connector" >>= withObject "selected connector" (\c -> (,) <$> c .: "tag" <*> c .: "value")
      pure (name,binding,kind,config)
