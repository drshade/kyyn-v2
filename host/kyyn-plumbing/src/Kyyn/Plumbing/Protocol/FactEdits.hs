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

-- | Bind fact operations to one already checked domain root.
factEditBindings :: RootContract -> Either String FileTree
factEditBindings contract = do
  let declarations = collectionContracts (rootSchema contract)
      names = [constructor field | CollectionContract _ field _ _ <- declarations]
  if length names /= length (nub names) then Left "Fact-edit constructor names collide"
    else pure ()
  bindingPath <- relativePath "Kyyn/Workspace/FactEdits.hs"
  codecPath <- relativePath "KyynFactEditCodec.hs"
  codecs <- if null declarations then pure (unlines
    ["module KyynFactEditCodec where", "import Kyyn.Runtime.Json", "import Kyyn.Workspace.FactEdits (RootEdit)",
     "rootCodec :: Codec RootEdit", "rootCodec = Codec (\\value -> value `seq` error \"Uninhabited RootEdit\") (\\_ -> Left \"This root has no fact collections\")"])
    else generateCodecs "KyynFactEditCodec" (factEditType contract)
  let root = haskellType (rootType (rootSchema contract))
      source = unlines $
        ["{-# LANGUAGE EmptyDataDecls #-}",
         "module Kyyn.Workspace.FactEdits (RootEdit(..), applyRootEdit) where",
         "import qualified Kyyn.Evolution.Proposal as Proposal",
         "import Kyyn.Edit (Edit, within)",
         "import qualified Kyyn.Edit.Internal as Internal", "import qualified Kyyn.Optics as Optics"] ++
        ["import qualified " ++ name | name <- nub
          (typeModules (rootType (rootSchema contract)))] ++
        ["data RootEdit" ++ (if null declarations then "" else " = " ++ intercalate " | "
           [constructor field ++ " (Proposal.FactEdit " ++ haskellType payload ++ ")" |
             CollectionContract _ field payload _ <- declarations]),
         "applyRootEdit :: RootEdit -> Edit " ++ root ++ " ()"] ++
        ["applyRootEdit value = value `seq` error \"Uninhabited RootEdit\"" | null declarations] ++
        ["applyRootEdit (" ++ constructor field ++ " operation) = within (Internal.Collection " ++ show name ++
          " (Optics.lens " ++ definingModule root ++ "." ++ field ++ " (\\root value -> root { " ++ definingModule root ++ "." ++ field ++
          " = value }))) (Proposal.applyFactEdit operation)" |
           CollectionContract name field _ _ <- declarations]
  fileTree [(bindingPath,utf8 source),(codecPath,utf8 codecs)]
  where utf8 = Text.encodeUtf8 . Text.pack

constructor :: String -> String
constructor field = "Edit_" ++ field
