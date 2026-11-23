{-# LANGUAGE OverloadedStrings, OverloadedRecordDot #-}
module Kyyn.Composition.FlowViewing (viewFlow) where

import Control.Monad (forM)
import Data.Aeson (object, (.=))
import Data.Aeson.Types (parseEither)
import Data.List (find)
import Data.Maybe (isJust)
import Data.Text (Text)
import Lucid (Html)
import Kyyn.Configuration (Host, SelectedKb(..), selectKnowledgeBase)
import Kyyn.Composition.FlowValues (readFlowValues)
import Kyyn.Composition.Runtime (runBase)
import Kyyn.Domain.Path (DirectoryScope)
import Kyyn.Domain.Diagnostic (errorDiagnostic)
import Kyyn.Domain.FlowInstance
import Kyyn.Plumbing.Interpreter.DocumentPersistence (runDocumentPersistenceIO)
import Kyyn.Plumbing.Protocol.Tool (decodeFlowValue)
import Kyyn.Porcelain.Capability.FlowStore (listInstances)
import Kyyn.Porcelain.Interpreter.FlowStore (runFlowStore)
import Kyyn.Porcelain.Interpreter.FlowJournal (tryFlowWriterLock)
import Kyyn.Surfaces.Result (Response, refusal, operationalFailure)
import Kyyn.Web.Flows (flowIndex, flowPage)

-- Catalog, captured contract metadata and try-lock reads only: no current
-- root source, guest executable or secrets.
viewFlow :: Host -> DirectoryScope -> [Text] -> IO (Either Response (Html ()))
viewFlow host scope route = do
  selected <- selectKnowledgeBase host scope
  case selected of
    Left problem -> pure (Left problem)
    Right (SelectedKb kb _ _) -> do
      result <- runBase host . runDocumentPersistenceIO . runFlowStore kb $ do
        catalog <- listInstances
        items <- forM catalog $ \item -> do
          interrupted <- if item.status == Running then isJust <$> tryFlowWriterLock kb item.instanceId (pure ()) else pure False
          pure (item,interrupted)
        case route of
          ["flows"] -> pure (Right (flowIndex items))
          ["flows",name] -> case flowInstanceId name of
            Left message -> pure (Left (refusal [errorDiagnostic "flow.request" message]))
            Right identity -> case find ((== identity) . (.instanceId) . fst) items of
              Nothing -> pure (Left (refusal [errorDiagnostic "flow.unknown" "This instance does not exist or has been cleared"]))
              Just (item,interrupted) -> do
                values <- readFlowValues item
                pure (Right (flowPage item interrupted values
                  [(child,state) | (child,state) <- items, child.parent == Just identity]
                  [(wait.waitId,either (\message -> object ["unavailable" .= message]) id
                      (parseEither decodeFlowValue wait.descriptor)) | wait <- item.waits]))
          _ -> pure (Left (refusal [errorDiagnostic "flow.unknown" "Unknown flow route"]))
      pure (either (Left . operationalFailure) id result)
