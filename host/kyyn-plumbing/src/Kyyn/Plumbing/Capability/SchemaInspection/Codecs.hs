module Kyyn.Plumbing.Capability.SchemaInspection.Codecs (generateCodecs) where

import Data.List (intercalate, nub, elemIndex)
import Kyyn.Domain.DataType

generateCodecs :: DataType -> Either String String
generateCodecs root = do
  _ <- shapeOf root
  definitions <- mapM codec types
  pure $ unlines $
    ["module KyynGeneratedCodec (rootCodec) where", "import Kyyn.Runtime.Json"] ++
    ["import qualified " ++ name | name <- nub [definingModule n | Algebraic n _ _ <- types]] ++
    ["rootCodec :: Codec " ++ haskellType root, "rootCodec = codec0"] ++ concat definitions
  where
    types = reachableTypes root
    ref t = maybe (error "reachableTypes omitted a dependency") (("codec" ++) . show) (elemIndex t types)
    codec t = do
      body <- definition (ref t) t
      pure ([ref t ++ " :: Codec " ++ haskellType t] ++ body)
    definition name StringType = pure [name ++ " = stringCodec"]
    definition name IntegerType = pure [name ++ " = integerCodec"]
    definition name BoolType = pure [name ++ " = boolCodec"]
    definition name (ListType t) = pure [name ++ " = listCodec " ++ ref t]
    definition name (OptionalType t) = pure [name ++ " = optionalCodec " ++ ref t]
    definition name (Algebraic _ _ constructors) = do
      let enc = name ++ "Encode"; dec = name ++ "Decode"
      pure $ [name ++ " = Codec " ++ enc ++ " " ++ dec] ++
        concatMap (encodeConstructor enc (isRecord constructors)) constructors ++
        decodeConstructors dec constructors
    encodeConstructor enc asRecord (Constructor name fs) =
      [enc ++ " (" ++ unwords (name : variables fs) ++ ") = " ++
        if asRecord then object fs
        else "tagged " ++ show (shortName name) ++ " " ++ payload fs]
    payload [] = "Nothing"
    payload fs | allNamed fs = "(Just (" ++ object fs ++ "))"
    payload [(_,t)] = "(Just (encodeWith " ++ ref t ++ " v0))"
    payload _ = error "unsupported constructor passed validation"
    object fs = "record [" ++ intercalate ", "
      ["(" ++ show n ++ ", encodeWith " ++ ref t ++ " " ++ v ++ ")"
      | ((Just n,t),v) <- zip fs (variables fs)] ++ "]"
    decodeConstructors dec cs@[Constructor name fs] | isRecord cs =
      [dec ++ " value = do"] ++ decodeRecord "  " name fs "value"
    decodeConstructors dec cs =
      [dec ++ " value = do", "  (name, payload) <- variant value", "  case (name, payload) of"] ++
      concatMap decodeArm cs ++ ["    _ -> Left \"unknown constructor tag or payload shape\""]
    decodeArm (Constructor name []) = ["    (" ++ show (shortName name) ++ ", Nothing) -> Right " ++ name]
    decodeArm (Constructor name fs) | allNamed fs =
      ["    (" ++ show (shortName name) ++ ", Just value) -> at " ++ show (shortName name ++ ".value") ++ " $ do"] ++
      decodeRecord "      " name fs "value"
    decodeArm (Constructor name [(_,t)]) =
      ["    (" ++ show (shortName name) ++ ", Just value) -> " ++ name ++
       " <$> at " ++ show (shortName name ++ ".value") ++ " (decodeWith " ++ ref t ++ " value)"]
    decodeArm _ = error "unsupported constructor passed validation"
    decodeRecord indent name fs value =
      [indent ++ "values <- fields " ++ show [n | (Just n,_) <- fs] ++ " " ++ value] ++
      [indent ++ v ++ " <- field " ++ show n ++ " " ++ ref t ++ " values"
      | ((Just n,t),v) <- zip fs (variables fs)] ++
      [indent ++ "pure (" ++ unwords (name : variables fs) ++ ")"]

variables :: [a] -> [String]
variables fs = ["v" ++ show i | i <- [0 .. length fs - 1]]

allNamed :: [(Maybe String, a)] -> Bool
allNamed = all (\(name,_) -> name /= Nothing)

isRecord :: [Constructor] -> Bool
isRecord [Constructor _ fs] = not (null fs) && allNamed fs
isRecord _ = False

shortName :: String -> String
shortName = reverse . takeWhile (/= '.') . reverse
