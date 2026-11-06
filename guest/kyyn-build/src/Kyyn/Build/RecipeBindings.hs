{-# LANGUAGE OverloadedStrings, OverloadedRecordDot #-}
module Kyyn.Build.RecipeBindings (writeRecipeBindings, writeEvolutionBindings) where

import Control.Monad (forM_, when)
import Data.List (nub)
import qualified Data.Text as Text
import System.Directory (createDirectoryIfMissing, doesFileExist)
import System.FilePath ((</>), takeDirectory)
import Kyyn.Build.Manifest
import Kyyn.Types.SchemaMetadata

-- Same-schema recipe flows use the selected Root for both edit endpoints. The
-- evolution builder supplies distinct endpoints when schema migration is needed.
writeRecipeBindings :: FilePath -> [FilePath] -> Manifest -> SchemaMetadata -> IO ()
writeRecipeBindings generated roots manifest metadata =
  writeEvolutionBindings generated roots (manifest.schemaType,metadata) (manifest.schemaType,metadata)

writeEvolutionBindings :: FilePath -> [FilePath] -> (Reference,SchemaMetadata) -> (Reference,SchemaMetadata) -> IO ()
writeEvolutionBindings generated roots (before,beforeMetadata) (after,afterMetadata@(SchemaMetadata _ _ collections)) = do
  let root = Text.unpack (referenceName after)
      beforeRoot = Text.unpack (referenceName before)
      imports = ["import qualified " ++ Text.unpack name | name <- nub [referenceModule before,referenceModule after]]
      header name = ["{-# LANGUAGE TemplateHaskell, DeriveGeneric, DerivingStrategies, DeriveAnyClass, EmptyCase, DataKinds, TypeApplications, OverloadedStrings #-}",
        "module " ++ name ++ " where"]
  write "Kyyn.Workspace.FactEdits" (unlines
    (header "Kyyn.Workspace.FactEdits" ++ imports ++
     ["import Kyyn.Build.Edits (rootEdits)","import qualified Kyyn.Edit as Edit",
      "import qualified Kyyn.Runtime.Bindings as Bindings", "import qualified Kyyn.Optics as Optics",
      "import qualified Kyyn.Evolution.Proposal as Proposal",
      "$(rootEdits ''" ++ root ++ " " ++ show [(Text.unpack name,Text.unpack field) | CollectionDecl name field _ <- collections] ++ ")"]))
  write "KyynFactEditCodec" (unlines
    (["{-# LANGUAGE EmptyCase, TypeApplications #-}", "module KyynFactEditCodec where",
      "import Kyyn.Runtime.Json (Codec(..))", "import Kyyn.Workspace.FactEdits (RootEdit)",
      "import qualified Kyyn.Runtime.Bindings as Bindings", "rootCodec :: Codec RootEdit"] ++
     if null collections then ["rootCodec = Codec (\\value -> case value of {}) (\\_ -> Left \"This Root has no fact collections\")"]
     else ["rootCodec = either (error . show) id (Bindings.contractCodec @RootEdit)"]))
  forM_ [("Before",beforeRoot,beforeMetadata),("After",root,afterMetadata)] $ \(endpoint,selected,SchemaMetadata _ _ fields) ->
    write ("Kyyn.Workspace." ++ endpoint) (unlines
      (header ("Kyyn.Workspace." ++ endpoint) ++ imports ++
       ["import Kyyn.Evolution (KnowledgeBase, facts)", "import qualified Kyyn.Runtime.Bindings as Bindings",
        "import qualified Kyyn.Optics as Optics"] ++
       [Text.unpack field ++ " = Bindings.collection " ++ show name ++ " (facts . Optics.field @" ++ show field ++
        " @" ++ selected ++ ")" | CollectionDecl name field _ <- fields]))
  let knowledge selected = "(KnowledgeBase " ++ selected ++ ")"
      old = knowledge beforeRoot
      new = knowledge root
      binding name selected metadata =
        [name ++ " :: Internal.RootBinding " ++ knowledge selected,
         name ++ " = either (error . show) id (Internal.rootBinding @" ++ selected ++ " (" ++ show metadata ++ "))"]
  write "Kyyn.Workspace.Evolution" (unlines
    (["{-# LANGUAGE TypeApplications, OverloadedStrings #-}",
      "module Kyyn.Workspace.Evolution (module Kyyn.Evolution, editBefore, evolve, edit) where",
      "import Kyyn.Evolution", "import Kyyn.Types.SchemaMetadata", "import qualified Kyyn.Runtime.Bindings as Internal"] ++ imports ++
     binding "beforeRoot" beforeRoot beforeMetadata ++ binding "afterRoot" root afterMetadata ++
     ["evolve :: Rationale -> (" ++ old ++ " -> Either EvolutionFailure " ++ new ++ ") -> Evolution " ++ old ++ " " ++ new,
      "evolve = Internal.evolve beforeRoot afterRoot",
      "edit :: Rationale -> Edit " ++ new ++ " () -> Evolution " ++ new ++ " " ++ new,
      "edit = Internal.edit afterRoot",
      "editBefore :: Rationale -> Edit " ++ old ++ " () -> Evolution " ++ old ++ " " ++ old,
      "editBefore = Internal.edit beforeRoot"]))
  where
    write name source = do
      let relative = map (\c -> if c == '.' then '/' else c) name
          path = generated </> relative ++ ".hs"
      occupied <- or <$> traverse doesFileExist [root </> relative ++ extension | root <- roots, extension <- [".hs",".lhs"]]
      when occupied (fail ("Authored source collides with generated module " ++ name))
      createDirectoryIfMissing True (takeDirectory path)
      writeFile path source
