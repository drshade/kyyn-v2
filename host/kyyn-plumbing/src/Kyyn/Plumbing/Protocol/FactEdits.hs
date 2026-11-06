module Kyyn.Plumbing.Protocol.FactEdits (factEditType) where

import Kyyn.Domain.Contract
import Kyyn.Domain.DataType

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

constructor :: String -> String
constructor field = "Edit_" ++ field
