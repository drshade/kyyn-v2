{-# LANGUAGE RoleAnnotations, FlexibleContexts, ScopedTypeVariables, TypeApplications, OverloadedRecordDot, OverloadedStrings #-}
module Kyyn.Interactive.Control (FlowHandle, flowRef, flowRefTyped, startFlow) where

import qualified Agentic as A
import qualified Agentic.Contract as Contract
import qualified Agentic.Codec as Codec
import qualified Agentic.Schema as Schema
import qualified Agentic.Value as Value
import qualified Data.Text as Text
import Kyyn.Contract (CompiledContract(..), compileContract)
import Kyyn.Types.KnowledgeBase (RecipeId)
import Control.Monad.Trans.Except (ExceptT(..), throwE)
import Data.Text (Text)
import Type.Reflection (Typeable)
import Kyyn.Interactive.Internal (FlowRef(..))
import Kyyn.Types.FlowControl (FlowControl(..))
import Kyyn.Types.Plugin (FetchError(..))
import Kyyn.Types.Program (Program, Member, inject, request)

type role FlowHandle nominal
newtype FlowHandle output = FlowHandle Text deriving (Eq, Show)
instance Typeable output => Contract.Contract (FlowHandle output) where
  contract = Contract.nominal (Contract.mapStructure FlowHandle (\(FlowHandle identity) -> identity) (Contract.contract @Text))

handleCodec :: Codec.Codec (FlowHandle output)
handleCodec = Codec.primitive (Schema.SString Nothing) (\(FlowHandle identity) -> Value.String identity)
  (\value -> case value of Value.String identity -> Right (FlowHandle identity); _ -> Left "Expected a flow handle")

-- The value supplies its types without being evaluated; recursive references
-- therefore do not recursively construct a flow graph.
flowRef :: (Contract.Contract input, Contract.Contract output)
  => RecipeId -> A.Agentic m input output -> FlowRef input output
flowRef ident _ = flowRefTyped ident

-- Explicit witnesses break module cycles. The host checks both against the
-- captured child before publishing any instance.
flowRefTyped :: forall input output. (Contract.Contract input, Contract.Contract output)
  => RecipeId -> FlowRef input output
flowRefTyped ident = FlowRef ident ((,) <$> compileContract (Contract.contract @input) <*> compileContract (Contract.contract @output))

-- The library supplies the durable key. No author-chosen operation key is needed.
startFlow :: Member FlowControl calls => FlowRef input output
  -> A.Agentic (ExceptT FetchError (Program calls)) input (FlowHandle output)
startFlow (FlowRef reference contracts) = case contracts of
  Left problem -> A.act (\_ -> throwE (FetchError (Text.pack (show problem))))
  Right (input,output) -> A.durably input.codec handleCodec $ \key value -> case key of
    Nothing -> throwE (FetchError "startFlow requires hosted interactive execution")
    Just durable -> FlowHandle <$> ExceptT (request (inject
      (StartChild durable reference input.description output.description (input.codec.encode value))))
