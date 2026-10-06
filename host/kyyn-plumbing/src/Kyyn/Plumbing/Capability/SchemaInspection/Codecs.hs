module Kyyn.Plumbing.Capability.SchemaInspection.Codecs (generateCodecs, generateModelCodecs) where

import Data.List (intercalate, nub, elemIndex)
import Kyyn.Domain.DataType

generateCodecs :: String -> DataType -> Either String String
generateCodecs = generateWith "probabilityCodec"

generateModelCodecs :: String -> DataType -> Either String String
generateModelCodecs = generateWith "modelProbabilityCodec"

generateWith :: String -> String -> DataType -> Either String String
generateWith probability moduleName root = do
  _ <- shapeOf root
  definitions <- mapM codec types
  pure $ unlines $
    ["module " ++ moduleName ++ " (rootCodec) where", "import Kyyn.Runtime.Json"] ++
    (if ProbabilityType `elem` types then
      ["import qualified Agentic.Questions", "import Kyyn.Runtime.Probability (" ++ probability ++ ")"] else []) ++
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
    definition name ProbabilityType = pure [name ++ " = " ++ probability]
    definition name (ListType t) = pure [name ++ " = listCodec " ++ ref t]
    definition name (OptionalType t) = pure [name ++ " = optionalCodec " ++ ref t]
    definition name t | t == sdkFactIdType = pure
      [name ++ " = Codec (\\(Kyyn.Types.Fact.FactId value) -> encodeWith stringCodec value) (\\value -> Kyyn.Types.Fact.FactId <$> decodeWith stringCodec value)"]
    definition name t@(Algebraic _ _ original) = do
      let constructors = case sdkFactPayload t of
            Just p -> [Constructor "Kyyn.Types.Fact.Fact" [(Just "id", sdkFactIdType), (Just "value", p)]]
            Nothing -> original
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
      [indent ++ (if null fs then "_" else "values") ++ " <- fields " ++ show [n | (Just n,_) <- fs] ++ " " ++ value] ++
      [indent ++ v ++ " <- field " ++ show n ++ " " ++ ref t ++ " values"
      | ((Just n,t),v) <- zip fs (variables fs)] ++
      [indent ++ "pure (" ++ unwords (name : variables fs) ++ ")"]

variables :: [a] -> [String]
variables fs = ["v" ++ show i | i <- [0 .. length fs - 1]]

allNamed :: [(Maybe String, a)] -> Bool
allNamed = all (\(name,_) -> name /= Nothing)

shortName :: String -> String
shortName = reverse . takeWhile (/= '.') . reverse
