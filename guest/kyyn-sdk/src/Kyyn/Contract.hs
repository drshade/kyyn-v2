{-# LANGUAGE GADTs, RankNTypes, ScopedTypeVariables, TypeApplications, TypeOperators #-}
{-# LANGUAGE OverloadedStrings, OverloadedRecordDot, DuplicateRecordFields #-}
-- | Compile the single authored Agentic contract to Kyyn's exact wire profile.
module Kyyn.Contract
  ( Contract(..), CompiledContract(..), compileContract, compileWire
  , ProjectionError(..), Codec(..), Structure, Description
  ) where

import Agentic.Contract
  ( Contract(..), Structure(..), Fields(..), Case(..), Constructor(..), FieldStyle(..)
  , ProjectionError(..), ScalarInfo(..), Codec(..), Outline(..), OutlineField(..), OutlineCase(..), compileWith, compileFieldsWith
  , compileCaseWith, outline )
import qualified Agentic.Codec as C
import qualified Agentic.Schema as S
import Agentic.Value (Value(..))
import Agentic.Questions (Probability)
import Control.Monad (unless)
import Data.Kind (Type)
import Data.Fixed (Fixed, E0, E1, E2, E3, E6, E9, E12)
import Data.List (nub, sort)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time (Day, UTCTime)
import Numeric.Natural (Natural)
import Type.Reflection
import Kyyn.Contract.Scalars
import Kyyn.Types.Contract (Description)
import qualified Kyyn.Types.Contract as D
import Kyyn.Types.Fact (FactId)
import Kyyn.Types.Blob (BlobRef)

data CompiledContract a = CompiledContract
  { description :: Description, codec :: Codec a }

compileContract :: Structure a -> Either ProjectionError (CompiledContract a)
compileContract structure = do
  finite [] structure
  compiled <- wire structure
  wireDescription <- lowerOutline (outline structure)
  either failure pure (D.validateDescription wireDescription)
  pure (CompiledContract wireDescription compiled)

compileWire :: Structure a -> Either ProjectionError (Codec a)
compileWire = fmap codec . compileContract

-- Named nodes let us reject recursive values before traversing an infinite outline.
finite :: [SomeTypeRep] -> Structure a -> Either ProjectionError ()
finite seen structure = case structure of
  Named rep child
    | SomeTypeRep rep `elem` seen -> failure ("recursive contract: " <> T.pack (show rep))
    | otherwise -> finite (SomeTypeRep rep : seen) child
  Scalar _ _ -> Right ()
  Record _ fs -> fieldsFinite seen fs
  Sum cs -> mapM_ (\(Case _ _ _ _ fs) -> fieldsFinite seen fs) cs
  List x -> finite seen x
  Optional x -> finite seen x
  Unit -> Right ()
  Mapped _ _ x -> finite seen x
  Checked _ _ x -> finite seen x
  Documented _ x -> finite seen x

fieldsFinite :: [SomeTypeRep] -> Fields r a -> Either ProjectionError ()
fieldsFinite seen fs = case fs of
  Pure _ -> Right ()
  Apply f x -> fieldsFinite seen f >> fieldsFinite seen x
  Field _ _ child _ -> finite seen child

failure :: Text -> Either ProjectionError a
failure = Left . ProjectionError []

wire :: Structure a -> Either ProjectionError (Codec a)
wire = compileWith rules

rules :: forall a. Structure a -> Maybe (Either ProjectionError (Codec a))
rules structure = case structure of
  Scalar _ _ -> Just (snd <$> scalarProjection structure)
  Optional child -> Just $ optionalWire <$> wire child
  Unit -> Just $ Right $ Codec (S.schemaOf (S.SObject [])) (const (Object [])) $ \v -> do
    _ <- object [] v
    Right ()
  Record con fs -> Just $ do
    obj <- compileFieldsWith wire fs
    uniqueFields obj.fields
    if null obj.fields || con.style == RecordFields
      then pure (recordWire obj)
      else sumWire [(con, C.CaseCodec con.name Nothing obj.fields (Just . obj.encode) obj.decode)]
  Sum cs -> Just $ do
    compiled <- mapM (\c@(Case con _ _ _ _) -> (,) con <$> compileCaseWith wire c) cs
    unless (length (nub (map (\(_,c) -> c.tag) compiled)) == length compiled)
      (failure "duplicate constructor names")
    mapM_ (uniqueFields . (\(_,c) -> c.fields)) compiled
    case compiled of
      [(_,c)] | null c.fields -> pure $ Codec (S.schemaOf (S.SObject [])) (const (Object [])) $ \v -> object [] v >> c.decode []
      _ -> sumWire compiled
  _ -> Nothing

uniqueFields :: [S.Field] -> Either ProjectionError ()
uniqueFields fields = unless (length names == length (nub names)) (failure "duplicate field names")
  where names = [name | S.Field name _ _ <- fields]

recordWire :: C.ObjectCodec a a -> Codec a
recordWire obj = Codec (S.schemaOf (S.SObject obj.fields)) (Object . obj.encode)
  (\v -> object [name | S.Field name _ _ <- obj.fields] v >>= obj.decode)

object :: [Text] -> Value -> Either Text [(Text, Value)]
object expected (Object fields)
  | sort (map fst fields) == sort expected = Right fields
  | otherwise = Left ("expected exactly these fields: " <> T.intercalate ", " expected)
object _ _ = Left "expected an object"

optionalWire :: Codec a -> Codec (Maybe a)
optionalWire inner = Codec
  (S.schemaOf (S.SSum [S.Variant "None" Nothing [], S.Variant "Some" Nothing [S.Field "value" inner.schema True]]))
  (\x -> case x of Nothing -> Object [("tag", String "None")]; Just v -> Object [("tag", String "Some"), ("value", inner.encode v)])
  (\v -> case v of
    Object fs -> case lookup "tag" fs of
      Just (String "None") -> object ["tag"] v >> Right Nothing
      Just (String "Some") -> do
        checked <- object ["tag", "value"] v
        maybe (Left "missing optional payload") (fmap Just . inner.decode) (lookup "value" checked)
      _ -> Left "expected None or Some tag"
    _ -> Left "expected a tagged optional")

sumWire :: forall a. [(Constructor, C.CaseCodec a)] -> Either ProjectionError (Codec a)
sumWire cases = do
  unless (not (null cases)) (failure "empty sums are unsupported")
  payloads <- mapM payload cases
  pure $ Codec (S.schemaOf (S.SSum [S.Variant c.tag c.doc fs | ((_,c), fs) <- zip cases payloads])) encode decode
  where
    payload :: (Constructor, C.CaseCodec a) -> Either ProjectionError [S.Field]
    payload (con,c)
      | null c.fields = Right []
      | con.style == RecordFields = Right [S.Field "value" (S.schemaOf (S.SObject c.fields)) True]
      | [S.Field _ schema _] <- c.fields = Right [S.Field "value" schema True]
      | otherwise = failure ("multiple positional fields are unsupported: " <> con.name)
    encode value = case [(con,c,fs) | (con,c) <- cases, Just fs <- [c.encode value]] of
      (con,c,fs):_ -> Object $ ("tag", String c.tag) :
        if null c.fields then [] else [("value", if con.style == RecordFields then Object fs else positionalValue fs)]
      [] -> error "Contract case matching did not cover its value"
    positionalValue [(_, value)] = value
    positionalValue _ = error "Contract positional case did not produce one payload"
    decode value@(Object fs) = case lookup "tag" fs of
      Just (String tag) -> case [(con,c) | (con,c) <- cases, c.tag == tag] of
        [(con,c)] -> do
          checked <- object (if null c.fields then ["tag"] else ["tag", "value"]) value
          if null c.fields then c.decode [] else case lookup "value" checked of
            Just p | con.style == RecordFields -> object [n | S.Field n _ _ <- c.fields] p >>= c.decode
            Just p | [S.Field name _ _] <- c.fields -> c.decode [(name,p)]
            _ -> Left "invalid constructor payload"
        _ -> Left ("unknown constructor: " <> tag)
      _ -> Left "expected a constructor tag"
    decode _ = Left "expected a tagged union"

scalarProjection :: forall a. Structure a -> Either ProjectionError (D.ScalarKind, Codec a)
scalarProjection (Scalar info _)
  | Just HRefl <- eqTypeRep (typeRep @a) (typeRep @Text) = known D.TextScalar $ C.primitive (S.SString Nothing) String $ \v -> case v of String t -> Right t; _ -> Left "expected text"
  | Just HRefl <- eqTypeRep (typeRep @a) (typeRep @Bool) = known D.BoolScalar $ C.primitive S.SBool Bool $ \v -> case v of Bool b -> Right b; _ -> Left "expected boolean"
  | Just HRefl <- eqTypeRep (typeRep @a) (typeRep @Integer) = known D.IntegerScalar integerText
  | Just HRefl <- eqTypeRep (typeRep @a) (typeRep @Int) = known (D.IntScalar (toInteger (minBound :: Int)) (toInteger (maxBound :: Int))) $ Codec integerText.schema (integerText.encode . toInteger) $ \v -> do
      n <- integerText.decode v
      if n < toInteger (minBound :: Int) || n > toInteger (maxBound :: Int) then Left "Int out of range" else Right (fromInteger n)
  | Just HRefl <- eqTypeRep (typeRep @a) (typeRep @Natural) = known D.NaturalScalar naturalText
  | Just HRefl <- eqTypeRep (typeRep @a) (typeRep @Probability) = known D.ProbabilityScalar probabilityText
  | Just HRefl <- eqTypeRep (typeRep @a) (typeRep @FactId) = known D.FactIdScalar factIdText
  | Just HRefl <- eqTypeRep (typeRep @a) (typeRep @BlobRef) = (\c -> (D.BlobRefScalar, blobCodec (optionalWire c))) <$> wire (contract @Text)
  | Just HRefl <- eqTypeRep (typeRep @a) (typeRep @Day) = known D.DateScalar dayText
  | Just HRefl <- eqTypeRep (typeRep @a) (typeRep @UTCTime) = known D.InstantScalar instantText
  | Just HRefl <- eqTypeRep (typeRep @a) (typeRep @(Fixed E0)) = known (D.DecimalScalar 1) decimalText
  | Just HRefl <- eqTypeRep (typeRep @a) (typeRep @(Fixed E1)) = known (D.DecimalScalar 10) decimalText
  | Just HRefl <- eqTypeRep (typeRep @a) (typeRep @(Fixed E2)) = known (D.DecimalScalar 100) decimalText
  | Just HRefl <- eqTypeRep (typeRep @a) (typeRep @(Fixed E3)) = known (D.DecimalScalar 1000) decimalText
  | Just HRefl <- eqTypeRep (typeRep @a) (typeRep @(Fixed E6)) = known (D.DecimalScalar 1000000) decimalText
  | Just HRefl <- eqTypeRep (typeRep @a) (typeRep @(Fixed E9)) = known (D.DecimalScalar 1000000000) decimalText
  | Just HRefl <- eqTypeRep (typeRep @a) (typeRep @(Fixed E12)) = known (D.DecimalScalar 1000000000000) decimalText
  | otherwise = failure ("unsupported scalar " <> T.pack (show (typeRep @a)) <> " (" <> info.name <> ")")
scalarProjection _ = failure "expected a scalar"

known :: D.ScalarKind -> Codec a -> Either ProjectionError (D.ScalarKind, Codec a)
known kind compiled = Right (kind,compiled)

resolvedType :: SomeTypeRep -> D.TypeIdentity
resolvedType (SomeTypeRep rep) =
  let (constructor,args) = splitApps rep
  in D.TypeIdentity (T.pack (tyConPackage constructor)) (T.pack (tyConModule constructor))
       (T.pack (tyConName constructor)) (map resolvedType args)

lowerOutline :: Outline -> Either ProjectionError Description
lowerOutline original = case original of
  OScalar identity@(SomeTypeRep (rep :: TypeRep t)) info ->
    case eqTypeRep (typeRepKind rep) (typeRep @Type) of
      Just HRefl -> withTypeable rep $ do
        (kind,_) <- scalarProjection (Scalar info Nothing :: Structure t)
        pure (D.ScalarDescription (resolvedType identity) kind info.name info.parameters)
      Nothing -> failure "scalar type has an unsupported kind"
  ONamed identity inner -> D.NamedDescription (resolvedType identity) <$> lowerOutline inner
  ORecord con fields -> D.RecordDescription con.name (style con.style) <$> mapM lowerField fields
  OSum cases -> D.SumDescription <$> mapM lowerCase cases
  OList inner -> D.ListDescription <$> lowerOutline inner
  OOptional inner -> D.OptionalDescription <$> lowerOutline inner
  OUnit -> Right D.UnitDescription
  OChecked label inner -> D.CheckedDescription label <$> lowerOutline inner
  ODocumented doc inner -> D.DocumentedDescription doc <$> lowerOutline inner
  where
    style RecordFields = D.NamedFields
    style PositionalFields = D.PositionalFields
    lowerField (OutlineField name doc inner) = D.FieldDescription name (maybe "" id doc) <$> lowerOutline inner
    lowerCase (OutlineCase con doc fields) = D.CaseDescription con.name (maybe "" id doc) (style con.style) <$> mapM lowerField fields
