-- One facade for inspection and execution; only its captured data differs.
module Kyyn.Build.FrozenProposal (writeFrozenProposal) where

import Data.Aeson (Value, encode)
import qualified Data.ByteString.Lazy as Lazy
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import System.FilePath ((</>))

writeFrozenProposal :: FilePath -> Maybe (Value, Bool) -> IO ()
writeFrozenProposal generated selected = writeFile (generated </> "KyynFrozenProposal.hs") (unlines
  [ "module KyynFrozenProposal (frozen, proposal) where",
   "import Kyyn.Workspace.Evolution", "import Kyyn.Workspace.FactEdits (RootEdit, applyRootEdit)",
   "import qualified KyynFactEditCodec", "import qualified KyynRecipeStateCodec",
   "import Kyyn.Runtime.Bindings (rejectEvolution)",
   "import Kyyn.Types.Evolution (EvolutionFailure(..))",
   "import Kyyn.Types.Diagnostic (Diagnostic(..), Severity(..))",
   "import Kyyn.Runtime.Json", "import qualified Data.Text as Text", "import Kyyn.Runtime.Proposal (recipeProposalCodec)",
   "-- | Apply the captured proposal without invoking its recipe again.",
   "frozen :: RecipeEvolution Root RecipeState",
   "frozen = case proposal of",
   "  Right (RecipeProposal steps state) -> foldr ((<>) . step) (" ++ finalStep ++ ") steps",
   "  Left message -> rejectEvolution (EvolutionFailure [Diagnostic Error \"proposal.decode\" (Text.pack message) Nothing])",
   "step (ProposedStep why operations) = recipeEdit why (editFacts (mapM_ applyRootEdit operations))",
   "proposal :: Either String (RecipeProposal RootEdit RecipeState)",
   "proposal = " ++ body])
  where
    finalStep = case selected of
      Just (_,True) -> "recipeEdit (Rationale \"Update recipe state\" []) (putRecipeState state)"
      _ -> "identityEvolution"
    body = case selected of
      Nothing -> "Left \"discovery build: proposal data is not loaded\""
      Just (value,_) -> "parseValue " ++ show (Text.unpack (Text.decodeUtf8 (Lazy.toStrict (encode value)))) ++
        " >>= decodeWith (recipeProposalCodec KyynFactEditCodec.rootCodec KyynRecipeStateCodec.rootCodec)"
