{-# LANGUAGE OverloadedStrings, OverloadedRecordDot #-}
module Kyyn.Build.RecipeBindings (writeRecipeBindings) where

import Control.Monad (forM_, when)
import qualified Data.Text as Text
import System.Directory (createDirectoryIfMissing, doesFileExist)
import System.FilePath ((</>), takeDirectory)
import Kyyn.Build.Manifest
import Kyyn.Types.SchemaMetadata

-- Same-schema recipe flows use the selected Root for both edit endpoints. The
-- evolution builder supplies distinct endpoints when schema migration is needed.
writeRecipeBindings :: FilePath -> [FilePath] -> Manifest -> SchemaMetadata -> IO ()
writeRecipeBindings generated roots manifest (SchemaMetadata _ _ collections) = do
  let root = Text.unpack (referenceName manifest.schemaType)
      imports = ["import qualified " ++ Text.unpack (referenceModule manifest.schemaType),
        "import qualified " ++ Text.unpack (referenceModule manifest.schemaMetadata)]
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
  forM_ ["Before","After"] $ \endpoint -> write ("Kyyn.Workspace." ++ endpoint) (unlines
    (header ("Kyyn.Workspace." ++ endpoint) ++ imports ++
     ["import Kyyn.Evolution (KnowledgeBase, facts)", "import qualified Kyyn.Runtime.Bindings as Bindings",
      "import qualified Kyyn.Optics as Optics"] ++
     [Text.unpack field ++ " = Bindings.collection " ++ show name ++ " (facts . Optics.field @" ++ show field ++
      " @" ++ root ++ ")" | CollectionDecl name field _ <- collections]))
  write "Kyyn.Workspace.Evolution" (unlines
    (["{-# LANGUAGE TypeApplications #-}",
      "module Kyyn.Workspace.Evolution (module Kyyn.Evolution, editBefore, evolve, edit) where",
      "import Kyyn.Evolution", "import qualified Kyyn.Runtime.Bindings as Internal"] ++ imports ++
     ["selectedRoot :: Internal.RootBinding (KnowledgeBase " ++ root ++ ")",
      "selectedRoot = either (error . show) id (Internal.rootBinding @" ++ root ++ " " ++ Text.unpack (referenceName manifest.schemaMetadata) ++ ")",
      "evolve :: Rationale -> (KnowledgeBase " ++ root ++ " -> Either EvolutionFailure (KnowledgeBase " ++ root ++ ")) -> Evolution (KnowledgeBase " ++ root ++ ") (KnowledgeBase " ++ root ++ ")",
      "evolve = Internal.evolve selectedRoot selectedRoot",
      "edit :: Rationale -> Edit (KnowledgeBase " ++ root ++ ") () -> Evolution (KnowledgeBase " ++ root ++ ") (KnowledgeBase " ++ root ++ ")",
      "edit = Internal.edit selectedRoot", "editBefore = edit"]))
  where
    write name source = do
      let relative = map (\c -> if c == '.' then '/' else c) name
          path = generated </> relative ++ ".hs"
      occupied <- or <$> traverse doesFileExist [root </> relative ++ extension | root <- roots, extension <- [".hs",".lhs"]]
      when occupied (fail ("Authored source collides with generated module " ++ name))
      createDirectoryIfMissing True (takeDirectory path)
      writeFile path source
