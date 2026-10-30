{-# LANGUAGE GADTs, RankNTypes #-}
module Kyyn.Runtime.Concurrent
  ( Exchange(..), WireRequest(..), Reply, metadataExchange, executeExchange
  , executeConcurrent, acquisitionInput, runConcurrent
  ) where

import qualified Data.ByteString as Bytes
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import Text.JSON.Types (JSValue)
import Kyyn.Runtime.Json
import Kyyn.Runtime.Transport
import Kyyn.Types.Program
import Kyyn.Types.Plugin (EvidenceSnapshot(..))

type Reply = (JSValue,Bytes.ByteString)
data WireRequest = WireRequest String String JSValue Bytes.ByteString
data Exchange a = Exchange WireRequest (Reply -> Either String a)

metadataExchange :: String -> String -> JSValue -> Codec a -> Exchange a
metadataExchange capability method arguments codec = Exchange
  (WireRequest capability method arguments Bytes.empty) $ \(value,body) ->
    if Bytes.null body then decodeWith codec value else Left "Unexpected raw body"

executeExchange :: Transport -> Integer -> Exchange a -> IO a
executeExchange transport identity (Exchange request decode) = do
  replies <- exchangeRound transport False [(identity,request)]
  case replies of
    [reply] -> either fail pure (decode reply)
    _ -> fail "Missing host response"

acquisitionInput :: Transport -> Codec a -> IO (a,EvidenceSnapshot payload,Int)
acquisitionInput transport codec = do
  input <- readJson transport
  either fail pure $ do
    values <- parseValue input >>= fields ["arguments","snapshot","concurrency"]
    arguments <- field "arguments" codec values
    snapshot <- EvidenceSnapshot <$> field "snapshot" textCodec values
    width <- field "concurrency" integerCodec values
    if width < 1 || width > 8 then Left "Invalid host concurrency width"
      else Right (arguments,snapshot,fromInteger width)

-- Fairness is per leaf, including leaves of nested groups. A collapsed nested
-- group returns to its parent path and may rotate behind its siblings once.
-- Typed continuations never leave this tree. Only WireRequest and Reply cross the pipe.
data Tree a where
  Done :: a -> Tree a
  Await :: Exchange x -> (x -> Tree a) -> Tree a
  Group :: [Tree x] -> ([x] -> Tree a) -> Tree a
  GroupEither :: [Tree (Either e x)] -> (Either e [x] -> Tree a) -> Tree a

type Path = [Int]

lower :: (forall x. request x -> Exchange x) -> Program request a -> Tree a
lower _ (Pure value) = Done value
lower handle (Request call next) = Await (handle call) (lower handle . next)
lower handle (Concurrent branches next) = Group (map (lower handle) branches) (lower handle . next)
lower handle (ConcurrentEither branches next) = GroupEither (map (lower handle) branches) (lower handle . next)

normalise :: Tree a -> Tree a
normalise (Group branches next) =
  let ready = map normalise branches
  in case completed ready of
    Just values -> normalise (next values)
    Nothing -> Group ready next
normalise (GroupEither branches next) =
  let ready = map normalise branches
  in case [problem | Done (Left problem) <- ready] of
    problem:_ -> normalise (next (Left problem))
    [] -> case completed ready of
      Just values -> normalise (next (sequence values))
      Nothing -> GroupEither ready next
normalise tree = tree

completed :: [Tree a] -> Maybe [a]
completed [] = Just []
completed (Done value:rest) = (value:) <$> completed rest
completed _ = Nothing

frontier :: Path -> Tree a -> [(Path,WireRequest)]
frontier path (Await (Exchange call _) _) = [(path,call)]
frontier path (Group branches _) = concat [frontier (path ++ [index]) branch | (index,branch) <- zip [0..] branches]
frontier path (GroupEither branches _) = concat [frontier (path ++ [index]) branch | (index,branch) <- zip [0..] branches]
frontier _ (Done _) = []

-- Decode every selected reply before normalising/resuming the next request round.
resume :: [(Path,Reply)] -> Path -> Tree a -> Either String (Tree a)
resume replies path tree@(Await (Exchange _ decode) next) = case lookup path replies of
  Nothing -> Right tree
  Just reply -> next <$> decode reply
resume replies path (Group branches next) =
  Group <$> sequence [resume replies (path ++ [index]) branch | (index,branch) <- zip [0..] branches] <*> pure next
resume replies path (GroupEither branches next) =
  GroupEither <$> sequence [resume replies (path ++ [index]) branch | (index,branch) <- zip [0..] branches] <*> pure next
resume _ _ tree@(Done _) = Right tree

-- The callback interprets one checked frame; tests can provide recorded replies.
runConcurrent :: Int -> (forall x. request x -> Exchange x)
  -> (Bool -> [(Integer,WireRequest)] -> IO [Reply]) -> Program request a -> IO a
runConcurrent width handle exchange program
  | width < 1 || width > 8 = fail "Invalid concurrency width"
  | otherwise = loop 1 Nothing (lower handle program)
  where
    loop serial cursor tree = case normalise tree of
      Done value -> pure value
      ready -> do
        let pending = frontier [] ready
            rotated = case cursor of
              Nothing -> pending
              Just previous -> filter ((> previous) . fst) pending ++ filter ((<= previous) . fst) pending
            selected = take width rotated
            grouped = case ready of Await _ _ -> False; _ -> True
        if null selected then fail "Concurrent scheduler has no runnable leaf" else pure ()
        replies <- exchange grouped (zip [serial..] (map snd selected))
        if length replies /= length selected then fail "Incomplete concurrent reply" else pure ()
        updated <- either fail pure (resume (zip (map fst selected) replies) [] ready)
        loop (serial + toInteger (length selected)) (Just (fst (last selected))) updated

executeConcurrent :: Transport -> Int -> Codec a -> (forall x. request x -> Exchange x)
  -> Program request a -> IO ()
executeConcurrent transport width codec handle program = do
  value <- runConcurrent width handle (exchangeRound transport) program
  writeValueFrame transport (record [("tag",encodeWith stringCodec "Completed"),("result",encodeWith codec value)]) Bytes.empty

exchangeRound :: Transport -> Bool -> [(Integer,WireRequest)] -> IO [Reply]
exchangeRound transport grouped requests = do
  let parts = [requestPart grouped identity request | (identity,request) <- requests]
      message = if grouped then record [("tag",encodeWith stringCodec "HostBatch"),("requests",encodeWith (listCodec identityCodec) parts)]
        else case parts of [part] -> part; _ -> error "Invalid singleton exchange"
      body = Bytes.concat [raw | (_,WireRequest _ _ _ raw) <- requests]
  writeValueFrame transport message body
  (metadata,raw) <- readFrame transport
  either fail pure $ do
    value <- parseValue (Text.unpack (Text.decodeUtf8 metadata))
    if grouped then do
      fieldsValue <- fields ["tag","responses"] value
      tag <- field "tag" stringCodec fieldsValue
      if tag /= "HostBatchResponse" then Left "Unexpected batch reply" else pure ()
      values <- field "responses" (listCodec identityCodec) fieldsValue
      if length values /= length requests then Left "Incomplete batch reply" else pure ()
      splitReplies (map fst requests) values raw
    else case requests of
      [(identity,_)] -> do
        fieldsValue <- fields ["tag","id","result"] value
        tag <- field "tag" stringCodec fieldsValue
        actual <- field "id" integerCodec fieldsValue
        if tag /= "HostResponse" || actual /= identity then Left "Unexpected host response tag or request ID" else pure ()
        result <- field "result" identityCodec fieldsValue
        pure [(result,raw)]
      _ -> Left "Invalid singleton exchange"

requestPart :: Bool -> Integer -> WireRequest -> JSValue
requestPart grouped identity (WireRequest capability method arguments body) = record
  ([("id",encodeWith integerCodec identity),("capability",encodeWith stringCodec capability),
    ("method",encodeWith stringCodec method),("arguments",arguments)] ++
    if grouped then [("bodyLength",encodeWith integerCodec (toInteger (Bytes.length body)))]
      else [("tag",encodeWith stringCodec "HostRequest")])

splitReplies :: [Integer] -> [JSValue] -> Bytes.ByteString -> Either String [Reply]
splitReplies [] [] raw | Bytes.null raw = Right []
                      | otherwise = Left "Trailing batch response body"
splitReplies (identity:rest) (value:values) raw = do
  members <- fields ["id","result","bodyLength"] value
  actual <- field "id" integerCodec members
  size <- field "bodyLength" integerCodec members
  if actual /= identity then Left "Unexpected batch response ID" else pure ()
  if size < 0 || size > toInteger (Bytes.length raw) then Left "Invalid batch response body length" else pure ()
  result <- field "result" identityCodec members
  let (body,remaining) = Bytes.splitAt (fromInteger size) raw
  ((result,body):) <$> splitReplies rest values remaining
splitReplies _ _ _ = Left "Incomplete batch reply"

identityCodec :: Codec JSValue
identityCodec = Codec id Right
