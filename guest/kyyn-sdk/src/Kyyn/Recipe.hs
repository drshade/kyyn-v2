{-# LANGUAGE NoFieldSelectors #-}
module Kyyn.Recipe
  ( RecipeInput(..), PendingEvidence(..), PendingChange(..)
  , RecipeId(..), EvidenceScope(..), EvidenceId(..)
  , Curation(..), Acknowledgement(..)
  , ProposedCuration(..), ProposedStep(..), FactEdit(..)
  , pendingItems, removedItems, scopes, acknowledgeAll, cite
  ) where

import Kyyn.Types.Curation
import Kyyn.Types.Evidence (EvidenceId(..), EvidenceRef(..))
import Kyyn.Evolution.Proposal

-- | The selected root and captured pending evidence supplied to a recipe flow.
data RecipeInput root = RecipeInput
  { recipe :: RecipeId, root :: root, pending :: [PendingEvidence] }
  deriving (Eq, Show)

-- | Pending changes for one captured connector instance. Use its scope in curation.
data PendingEvidence = PendingEvidence
  { scope :: EvidenceScope, changes :: [PendingChange] }
  -- | The producer changed. Reconcile these current IDs with the root;
  -- acknowledge the whole scope or leave it pending.
  | Reconciliation { scope :: EvidenceScope, currentIds :: [EvidenceId] }
  deriving (Eq, Show)

-- | Net changes since this recipe last acknowledged an evidence item.
data PendingChange = New EvidenceId | Updated EvidenceId | Removed EvidenceId
  deriving (Eq, Show)

-- | Readable new/updated items, or current items needing reconciliation, paired
-- with their connector scope. Preserves input order; excludes removals.
pendingItems :: [PendingEvidence] -> [(EvidenceScope, EvidenceId)]
pendingItems = concatMap items
  where
    items (PendingEvidence scope changes) = [(scope, ident) | change <- changes,
      ident <- case change of New i -> [i]; Updated i -> [i]; Removed _ -> []]
    items (Reconciliation scope ids) = [(scope, ident) | ident <- ids]

-- | Explicitly removed items paired with their scope. Reconciliation does not
-- enumerate removals; compare its current items with the KB yourself.
removedItems :: [PendingEvidence] -> [(EvidenceScope, EvidenceId)]
removedItems batches = [(scope, ident) | PendingEvidence scope changes <- batches,
  Removed ident <- changes]

-- | Captured scopes in input order, including empty batches and reconciliation.
scopes :: [PendingEvidence] -> [EvidenceScope]
scopes = map selected
  where
    selected (PendingEvidence scope _) = scope
    selected (Reconciliation scope _) = scope

-- | Explicitly declare every supplied batch fully handled, including producer
-- reconciliation. Call only after completing that work; this makes no decision
-- about whether processing succeeded.
acknowledgeAll :: RecipeInput root -> Curation
acknowledgeAll (RecipeInput recipe _ batches) = Curation recipe (map EntireBatch (scopes batches))

-- | Cite an opaque item ID within its connector instance. Add external links to
-- the reference separately when available; this does not resolve a source URI.
cite :: EvidenceScope -> EvidenceId -> EvidenceRef
cite (EvidenceScope plugin instanceName _) (EvidenceId ident) = EvidenceRef plugin instanceName ident []
