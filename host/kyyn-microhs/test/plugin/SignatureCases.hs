{-# LANGUAGE FlexibleContexts #-}
module SignatureCases where

import Kyyn.Plugin
import Kyyn.Plugin.Host
import qualified FolderSchema as Schema

data Box a = Box { item :: a }
type Payload = Box String
type Config = Schema.Config

ids :: ReadsEvidence row payload => EvidenceSnapshot payload -> Program row (Either FetchError [EvidenceId])
ids = listEvidenceIds

good :: Config -> EvidenceSnapshot Payload -> Acquisition Payload (Either FetchError [EvidenceChange Payload])
good _ snapshot = fmap (fmap (const [])) (ids snapshot)

goodOptions :: Config -> Maybe Schema.FetchOptions -> EvidenceSnapshot Payload -> Acquisition Payload (Either FetchError [EvidenceChange Payload])
goodOptions config _ = good config

goodRead :: String -> EvidenceSnapshot Payload -> CapturedRead Payload (Either FetchError String)
goodRead _ snapshot = fmap (fmap (const "read")) (ids snapshot)

badRow :: Config -> EvidenceSnapshot Payload -> CapturedRead Payload (Either FetchError [EvidenceChange Payload])
badRow _ _ = pure (Right [])

badResult :: Config -> EvidenceSnapshot Payload -> Acquisition Payload (Either FetchError String)
badResult _ _ = pure (Right "wrong")

badPayload :: Config -> EvidenceSnapshot Payload -> Acquisition String (Either FetchError [EvidenceChange String])
badPayload _ _ = pure (Right [])

badChange :: Config -> EvidenceSnapshot Payload -> Acquisition Payload (Either FetchError [EvidenceChange String])
badChange _ _ = pure (Right [])

badOptions :: Config -> Schema.FetchOptions -> EvidenceSnapshot Payload -> Acquisition Payload (Either FetchError [EvidenceChange Payload])
badOptions _ _ _ = pure (Right [])

badPolymorphic :: Eq a => a -> EvidenceSnapshot Payload -> Acquisition Payload (Either FetchError [EvidenceChange Payload])
badPolymorphic _ _ = pure (Right [])

badArity :: Config -> Acquisition Payload (Either FetchError [EvidenceChange Payload])
badArity _ = pure (Right [])

badFailure :: Config -> EvidenceSnapshot Payload -> Acquisition Payload (Either String [EvidenceChange Payload])
badFailure _ _ = pure (Right [])
