module Kyyn.Plumbing.Protocol.FactEdits (factEditBindings, factEditType) where

import Data.List (nub, intercalate)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import Kyyn.Domain.Contract
import Kyyn.Domain.DataType
import Kyyn.Domain.FileTree (FileTree, fileTree)
import Kyyn.Domain.Path (relativePath)
import Kyyn.Plumbing.Capability.SchemaInspection.Codecs (generateCodecs)

-- | A root-specific sum whose alternatives contain the collection payload types.
factEditType :: RootContract -> DataType
factEditType contract = Algebraic "Kyyn.Workspace.FactEdits.RootEdit" []
  [Constructor ("Kyyn.Workspace.FactEdits." ++ constructor field) [(Nothing, edits payload)] |
    CollectionContract _ field payload _ <- collectionContracts (rootSchema contract)]
  where
    edits payload = Algebraic "Kyyn.Evolution.Proposal.FactEdit" [payload]
      [Constructor "Kyyn.Evolution.Proposal.Append" [(Nothing, fact payload)],
       Constructor "Kyyn.Evolution.Proposal.Replace" [(Just "factId",sdkFactIdType),(Just "replacement",payload)],
       Constructor "Kyyn.Evolution.Proposal.Remove" [(Nothing,sdkFactIdType)]]
    fact payload = Algebraic "Kyyn.Types.Fact.Fact" [payload]
      [Constructor "Kyyn.Types.Fact.Fact" [(Nothing,sdkFactIdType),(Nothing,payload)]]

-- | Bind the proposal interpreter to one already checked root contract.
-- The ordinary workspace Evolution module supplies the recorded-step constructor.
factEditBindings :: RootContract -> Either String FileTree
factEditBindings contract = do
  let declarations = collectionContracts (rootSchema contract)
      names = [constructor field | CollectionContract _ field _ _ <- declarations]
  if null declarations then Left "Fact-edit proposals need a domain fact collection"
    else if length names /= length (nub names) then Left "Fact-edit constructor names collide"
    else pure ()
  bindingPath <- relativePath "Kyyn/Workspace/FactEdits.hs"
  codecPath <- relativePath "KyynFactEditCodec.hs"
  codecs <- generateCodecs "KyynFactEditCodec" (factEditType contract)
  let root = haskellType (rootType (rootSchema contract))
      source = unlines $
        ["module Kyyn.Workspace.FactEdits (RootEdit(..), proposalEvolution) where",
         "import qualified Kyyn.Evolution.Proposal as Proposal",
         "import Kyyn.Workspace.Evolution (Evolution, KnowledgeBase, Edit, identityEvolution, (>=>), withCuration, edit, within)",
         "import qualified Kyyn.Workspace.After as Collections"] ++
        ["import qualified " ++ name | name <- nub
          [definingModule name | Algebraic name _ _ <- reachableTypes (rootType (rootSchema contract))]] ++
        ["data RootEdit = " ++ intercalate " | "
           [constructor field ++ " (Proposal.FactEdit " ++ haskellType payload ++ ")" |
             CollectionContract _ field payload _ <- declarations],
         "applyRootEdit :: RootEdit -> Edit (KnowledgeBase " ++ root ++ ") ()"] ++
        ["applyRootEdit (" ++ constructor field ++ " operation) = within Collections." ++ field ++ " (Proposal.applyFactEdit operation)" |
           CollectionContract _ field _ _ <- declarations] ++
        ["proposalEvolution :: Proposal.ProposedCuration RootEdit -> Evolution (KnowledgeBase " ++ root ++ ") (KnowledgeBase " ++ root ++ ")",
         "proposalEvolution (Proposal.ProposedCuration steps curation) = withCuration curation (foldr ((>=>) . step) identityEvolution steps)",
         "  where step (Proposal.ProposedStep why operations) = edit why (mapM_ applyRootEdit operations)"]
  fileTree [(bindingPath,utf8 source),(codecPath,utf8 codecs)]
  where utf8 = Text.encodeUtf8 . Text.pack

constructor :: String -> String
constructor field = "Edit_" ++ field
