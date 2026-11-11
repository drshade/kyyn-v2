-- | Optional editable input declarations derived only from stored structure.
module Kyyn.Porcelain.Protocol.InputTypes (scaffoldInputTypes) where

import Control.Monad (unless)
import Control.Monad.Trans.State.Strict (StateT, evalStateT, get, put)
import Control.Monad.Trans.Class (lift)
import Data.Char (isAsciiLower, isAsciiUpper, isDigit)
import Data.List (intercalate, nub)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import Kyyn.Domain.DataType (Shape(..), ScalarKind(..))
import Kyyn.Domain.Diagnostic (Diagnostic, errorDiagnostic)
import Kyyn.Domain.FileTree (FileTree, fileTree)
import Kyyn.Domain.Path (relativePath)
import Kyyn.Domain.StoredSnapshot
import Kyyn.Types.Fact (Fact(..), FactId(..))

scaffoldInputTypes :: String -> StoredSnapshot -> Either [Diagnostic] (FileTree,[String])
scaffoldInputTypes revision (StoredSnapshot fields collections recipes) = do
  collected <- traverse collection (zip [1 :: Int ..] collections)
  let candidates = concatMap fst collected ++
        [("Field" ++ number index,"field " ++ show name,shape) | (index,(name,RecordedValue shape _)) <- zip [1..] fields] ++
        [("Recipe" ++ number index,"recipe " ++ show name,shape) |
          (index,Fact (FactId name) (RecordedRecipe _ (RecordedValue shape _))) <- zip [1..] recipes]
  entries <- traverse (\(name,label,shape) -> do
    source <- either (bad . ((label ++ ": ") ++)) Right (declarations shape)
    path <- either bad Right (relativePath ("Input/" ++ name ++ ".hs"))
    pure (path,Text.encodeUtf8 (Text.pack (unlines
      (["{-# LANGUAGE DeriveGeneric, DeriveAnyClass, DerivingStrategies, DuplicateRecordFields, NoFieldSelectors #-}",
        "-- Decoding view for " ++ label ++ "; base " ++ show revision ++ ".",
        "-- Text carriers do not claim the historical scalar meaning.",
        "module Input." ++ name ++ " where",
        "-- Edit these declarations to substitute compatible target scalar types."] ++
        ["import Data.Text (Text)" | "Text" `elem` words [if identifier c then c else ' ' | c <- unwords source]] ++
        ["import Numeric.Natural (Natural)" | "Natural" `elem` words [if identifier c then c else ' ' | c <- unwords source]] ++
        ["import GHC.Generics (Generic)" | any (\line -> take 5 line == "data ") source] ++
        ["import Kyyn.Contract (Contract)" | any (\line -> take 5 line == "data ") source] ++ source))))) candidates
  tree <- either bad Right (fileTree entries)
  pure (tree,concatMap snd collected)
  where
    collection (index,(name,members)) = case members of
      [] -> Right ([],["Collection " ++ show name ++ " is empty; no payload type can be recovered"])
      _ -> do
        shapes <- traverse (\(Fact _ (RecordedValue shape _)) -> case shape of
          Record values | Just payload <- lookup "value" values -> Right payload
          _ -> bad ("Collection " ++ show name ++ " has an invalid envelope")) members
        unless (length (nub shapes) == 1) (bad ("Collection " ++ show name ++ " has inconsistent stored payload shapes"))
        case shapes of
          shape : _ -> Right ([("Collection" ++ number index,"collection " ++ show name,shape)],[])
          [] -> bad "Missing collection shape"
    number n = let value = show (n :: Int) in replicate (max 0 (3 - length value)) '0' ++ value
    bad = Left . pure . errorDiagnostic "evolution.input-types"

declarations :: Shape -> Either String [String]
declarations shape = evalStateT (do
  (selected,body) <- describe "Value" shape
  pure (if selected == "Value" then body else ("type Value = " ++ selected) : body)) (1 :: Int,[])

-- The scaffold favours ordinary Generic/Contract declarations. Shapes that would
-- change under generic single-constructor encoding are diagnosed, not guessed.
describe :: String -> Shape -> StateT (Int,[String]) (Either String) (String,[String])
describe selected shape = case shape of
  Scalar TextScalar -> pure ("Text",[])
  Scalar IntegerScalar -> pure ("Integer",[])
  Scalar NaturalScalar -> pure ("Natural",[])
  Scalar BoolScalar -> pure ("Bool",[])
  List inner -> do
    (name,body) <- nested inner
    pure ("[" ++ name ++ "]",body)
  Optional inner -> do
    (name,body) <- nested inner
    pure ("(Maybe " ++ name ++ ")",body)
  Record [] -> pure ("()",[])
  Record fields -> do
    reserve [selected]
    (record,body) <- recordFields fields
    pure (selected,("data " ++ selected ++ " = " ++ selected ++ " { " ++ record ++ " }" ++ derivingClause) : body)
  Union cases -> do
    unless (length cases > 1) (lift (Left "A zero/single-alternative stored union requires an authored decoding view"))
    unless (all (constructorName . fst) cases) (lift (Left "Stored union alternatives are not legal Haskell constructor names"))
    reserve (map fst cases)
    parts <- traverse (\(name,payload) -> case payload of
      Nothing -> pure (name,[])
      Just (Record fields) | not (null fields) -> do
        (record,body) <- recordFields fields
        pure (name ++ " { " ++ record ++ " }",body)
      Just inner -> do
        (kind,body) <- nested inner
        pure (name ++ " (" ++ kind ++ ")",body)) cases
    pure (selected,("data " ++ selected ++ " = " ++ intercalate " | " (map fst parts) ++ derivingClause) : concatMap snd parts)
  _ -> lift (Left "Unsupported stored scalar/reference shape")
  where
    nested inner = do
      (index,names) <- get
      put (index + 1,names)
      describe ("InputValue" ++ show index) inner
    recordFields fields = do
      unless (all (fieldName . fst) fields) (lift (Left "Stored field labels are not legal Haskell field names"))
      parts <- traverse (\(name,inner) -> do
        (kind,body) <- nested inner
        pure (name ++ " :: " ++ kind,body)) fields
      pure (intercalate ", " (map fst parts),concatMap snd parts)
    reserve names = do
      (index,previous) <- get
      unless (all (`notElem` previous) names && length names == length (nub names))
        (lift (Left "Repeated constructor names require separately authored input modules"))
      put (index,previous ++ names)
    derivingClause = " deriving stock (Generic) deriving anyclass (Contract)"

fieldName :: String -> Bool
fieldName name = case name of
  first : rest -> isAsciiLower first && all identifier rest && name `notElem`
    ["as","case","class","data","default","deriving","do","else","family","forall","foreign","hiding",
     "if","import","in","infix","infixl","infixr","instance","let","mdo","module","newtype","of",
     "pattern","qualified","role","safe","then","type","unsafe","where"]
  [] -> False
constructorName :: String -> Bool
constructorName name = case name of first : rest -> isAsciiUpper first && all identifier rest; [] -> False
identifier :: Char -> Bool
identifier c = isAsciiLower c || isAsciiUpper c || isDigit c || c == '_' || c == '\''
