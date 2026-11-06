{-# LANGUAGE ScopedTypeVariables, TypeApplications, OverloadedRecordDot #-}
-- Constructors used by compiler-generated modules, separate from the author SDK.
module Kyyn.Runtime.Bindings (collection, contractCodec, RootBinding, rootBinding, evolve, edit) where

import Data.Text (Text)
import Kyyn.Contract
import Kyyn.Types.Fact (Fact)
import Kyyn.Types.SchemaMetadata (SchemaMetadata)
import Kyyn.Types.Guest (describeContract, DescribedContract(..))
import Kyyn.Optics (Lens')
import Kyyn.Edit.Internal (Collection(..))
import Kyyn.Evolution (KnowledgeBase)
import Kyyn.Evolution.Internal (RootBinding(..), evolve, edit)
import Kyyn.Runtime.Contract (runtimeCodec)
import Kyyn.Runtime.Evolution (knowledgeBaseCodec)
import qualified Kyyn.Runtime.Json as Wire

collection :: Text -> Lens' root [Fact value] -> Collection root value
collection = Collection

contractCodec :: forall value. Contract value => Either ProjectionError (Wire.Codec value)
contractCodec = runtimeCodec . (.codec) <$> compileContract (contract @value)

rootBinding :: forall root. Contract root => SchemaMetadata -> Either ProjectionError (RootBinding (KnowledgeBase root))
rootBinding metadata = do
  compiled <- compileContract (contract @root)
  let description = describeContract compiled.description metadata []
  pure (RootBinding description.identity (Wire.encodeWith (knowledgeBaseCodec (runtimeCodec compiled.codec))))
