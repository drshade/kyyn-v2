{-# LANGUAGE DeriveGeneric, OverloadedStrings, TupleSections #-}
-- | Structural storage types: deliberately no Haskell identities or semantic roles.
module Kyyn.Types.StoredShape (StoredShape(..), storedShape, canonicalShape) where

import Data.Aeson (ToJSON, FromJSON(..), genericParseJSON, defaultOptions)
import Data.List (sortOn, nub)
import Control.Monad (unless)
import qualified Data.Text as Text
import Data.Text (Text)
import GHC.Generics (Generic)
import Kyyn.Types.Contract

-- Integer values travel as exact decimal strings, never floating point numbers.
data StoredShape
  = StoredText | StoredInteger | StoredNatural | StoredBool
  | StoredRecord [(Text, StoredShape)]
  | StoredList StoredShape | StoredOptional StoredShape
  | StoredUnion [(Text, Maybe StoredShape)]
  deriving (Eq, Show, Generic)
instance ToJSON StoredShape
instance FromJSON StoredShape where
  parseJSON value = do
    shape <- genericParseJSON defaultOptions value
    either (fail . Text.unpack) (pure . canonicalShape) (check shape)
    where
      check shape = case shape of
        StoredRecord fields -> unique (map fst fields) >> mapM_ (check . snd) fields >> pure shape
        StoredUnion cases -> unique (map fst cases) >> mapM_ (mapM_ check . snd) cases >> pure shape
        StoredList inner -> check inner >> pure shape
        StoredOptional inner -> check inner >> pure shape
        _ -> pure shape
      unique names = unless (length names == length (nub names)) (Left "Duplicate stored shape labels")

canonicalShape :: StoredShape -> StoredShape
canonicalShape shape = case shape of
  StoredRecord fields -> StoredRecord (sortOn fst [(name,canonicalShape value) | (name,value) <- fields])
  StoredUnion cases -> StoredUnion (sortOn fst [(name,canonicalShape <$> value) | (name,value) <- cases])
  StoredList inner -> StoredList (canonicalShape inner)
  StoredOptional inner -> StoredOptional (canonicalShape inner)
  _ -> shape

storedShape :: Description -> Either Text StoredShape
storedShape = fmap canonicalShape . go
  where
    go description = case description of
      NamedDescription _ inner -> go inner
      CheckedDescription _ inner -> go inner
      DocumentedDescription _ inner -> go inner
      ScalarDescription _ kind _ _ -> Right (scalar kind)
      ListDescription inner -> StoredList <$> go inner
      OptionalDescription inner -> StoredOptional <$> go inner
      UnitDescription -> Right (StoredRecord [])
      RecordDescription name style fields
        | null fields || style == NamedFields -> record fields
        | otherwise -> StoredUnion . pure <$> arm (CaseDescription name "" style fields)
      SumDescription [CaseDescription _ _ _ []] -> Right (StoredRecord [])
      SumDescription cases -> StoredUnion <$> traverse arm cases
    record fields = StoredRecord <$> traverse (\(FieldDescription name _ inner) -> (name,) <$> go inner) fields
    arm (CaseDescription name _ style fields) = (name,) <$> case fields of
      [] -> Right Nothing
      _ | style == NamedFields -> Just <$> record fields
      [FieldDescription _ _ inner] -> Just <$> go inner
      _ -> Left "Multiple positional fields cannot be stored"
    scalar kind = case kind of
      IntegerScalar -> StoredInteger
      IntScalar _ _ -> StoredInteger
      NaturalScalar -> StoredNatural
      ProbabilityScalar -> StoredNatural
      BoolScalar -> StoredBool
      BlobRefScalar -> StoredRecord
        [("sha256",StoredText),("size",StoredInteger),("mediaType",StoredText),("name",StoredOptional StoredText)]
      _ -> StoredText
