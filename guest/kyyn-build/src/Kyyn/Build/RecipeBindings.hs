{-# LANGUAGE OverloadedStrings, OverloadedRecordDot #-}
module Kyyn.Build.RecipeBindings (writeRecipeBindings, writeRecipeEvolutionBindings, writeTargetEvolutionBindings) where

import Control.Monad (forM_, when)
import Data.List (nub)
import qualified Data.Text as Text
import System.Directory (createDirectoryIfMissing, doesFileExist)
import System.FilePath ((</>), takeDirectory)
import Kyyn.Build.Manifest
import Kyyn.Types.SchemaMetadata

writeRecipeBindings :: FilePath -> [FilePath] -> Manifest -> SchemaMetadata -> IO ()
writeRecipeBindings generated roots manifest metadata = writeBindings generated roots manifest.schemaType metadata

writeBindings :: FilePath -> [FilePath] -> Reference -> SchemaMetadata -> IO ()
writeBindings generated roots selectedRoot (SchemaMetadata _ _ collections) = do
  let root = Text.unpack (referenceName selectedRoot)
      header name = ["{-# LANGUAGE TemplateHaskell, DeriveGeneric, DerivingStrategies, DeriveAnyClass, EmptyCase, DataKinds, TypeApplications, OverloadedStrings #-}",
        "module " ++ name ++ " where"]
  write "Kyyn.Workspace.FactEdits" (unlines
    (header "Kyyn.Workspace.FactEdits" ++ ["import qualified " ++ Text.unpack (referenceModule selectedRoot)] ++
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
  write "Kyyn.Workspace.Target" (unlines
    (header "Kyyn.Workspace.Target" ++
     ["import qualified " ++ Text.unpack (referenceModule selectedRoot),
      "import Kyyn.Edit (Collection)", "import Kyyn.Evolution (KnowledgeBase, facts)", "import qualified Kyyn.Runtime.Bindings as Bindings",
      "import qualified Kyyn.Optics as Optics"] ++
     ["-- | Collection " ++ Text.unpack name ++ ".\n" ++ Text.unpack field ++ " = Bindings.collection " ++ show name ++ " (facts . Optics.field @" ++ show field ++
      " @" ++ root ++ ")" | CollectionDecl name field _ <- collections]))
  where
    write name source = do
      let relative = map (\c -> if c == '.' then '/' else c) name
          path = generated </> relative ++ ".hs"
      occupied <- or <$> traverse doesFileExist [root </> relative ++ extension | root <- roots, extension <- [".hs",".lhs"]]
      when occupied (fail ("Authored source collides with generated module " ++ name))
      createDirectoryIfMissing True (takeDirectory path)
      writeFile path source

-- The same-schema facade exposes the compiler-resolved state, including private
-- flow state aliases. Runtime codecs come from its ordinary Contract instance.
writeRecipeEvolutionBindings :: FilePath -> Reference -> SchemaMetadata -> String -> [String] -> IO ()
writeRecipeEvolutionBindings generated root metadata state imports = do
  let selected = Text.unpack (referenceName root)
      path = generated </> "Kyyn/Workspace/Evolution.hs"
  writeFile path (unlines
    (["{-# LANGUAGE TypeApplications, OverloadedStrings #-}",
      "module Kyyn.Workspace.Evolution (module Kyyn.Recipe, module Kyyn.Edit, Rationale(..), EvidenceRef(..), identityEvolution, Root, RecipeState, recipeEdit) where",
      "import Data.Text (Text)", "import Kyyn.Recipe hiding (recipeEdit)", "import qualified Kyyn.Recipe as Recipe", "import Kyyn.Edit", "import Kyyn.Evolution (Rationale(..), EvidenceRef(..))",
      "import Kyyn.Types.SchemaMetadata", "import qualified Kyyn.Runtime.Bindings as Bindings"] ++
     ["import qualified " ++ name | name <- nub (Text.unpack (referenceModule root) : imports)] ++
     ["type Root = " ++ selected, "type RecipeState = " ++ state,
      "recipeEdit :: Rationale -> RecipeEdit Root RecipeState () -> RecipeEvolution Root RecipeState",
      "recipeEdit = Recipe.recipeEdit",
      "identityEvolution :: RecipeEvolution Root RecipeState", "identityEvolution = mempty"]))
  writeFile (generated </> "KyynRecipeStateCodec.hs") (unlines
    ["{-# LANGUAGE TypeApplications #-}","module KyynRecipeStateCodec (rootCodec) where",
     "import Kyyn.Workspace.Evolution (RecipeState)","import qualified Kyyn.Runtime.Bindings as Bindings",
     "import Kyyn.Runtime.Json (Codec)", "rootCodec :: Codec RecipeState",
     "rootCodec = either (error . show) id (Bindings.contractCodec @RecipeState)"])
  let SchemaMetadata _ _ collections = metadata
  forM_ ["Target"] $ \endpoint -> do
    let name = "Kyyn.Workspace." ++ endpoint
    writeFile (generated </> "Kyyn/Workspace" </> endpoint ++ ".hs") (unlines
      (["{-# LANGUAGE DataKinds, TypeApplications, OverloadedStrings #-}","module " ++ name ++ " where",
        "import qualified " ++ Text.unpack (referenceModule root),
        "import Kyyn.Edit (Collection)", "import qualified Kyyn.Runtime.Bindings as Bindings", "import qualified Kyyn.Optics as Optics"] ++
       [Text.unpack field ++ " = Bindings.collection " ++ show label ++ " (Optics.field @" ++ show field ++ " @" ++ selected ++ ")"
        | CollectionDecl label field _ <- collections]))

-- Target-only generation shares the fact-edit module with ordinary recipe runs.
writeTargetEvolutionBindings :: FilePath -> [FilePath] -> Manifest -> SchemaMetadata -> IO ()
writeTargetEvolutionBindings generated roots manifest metadata@(SchemaMetadata _ _ collections) = do
  writeBindings generated roots manifest.schemaType metadata
  let root = Text.unpack (referenceName manifest.schemaType)
      rootModule = Text.unpack (referenceModule manifest.schemaType)
      directory = generated </> "Kyyn/Workspace"
  forM_ ["Kyyn/Workspace/Evolution","Kyyn/Workspace/Target/Fields"] $ \reserved -> do
    occupied <- or <$> traverse doesFileExist [source </> reserved ++ extension | source <- roots, extension <- [".hs",".lhs"]]
    when occupied (fail ("Authored source collides with generated module " ++ reserved))
  createDirectoryIfMissing True (directory </> "Target")
  writeFile (directory </> "Target/Fields.hs") (unlines
    ["{-# LANGUAGE TemplateHaskell #-}","module Kyyn.Workspace.Target.Fields where",
     "import Kyyn.Build.Edits (targetFields)","import qualified Kyyn.Runtime.TargetEvolution as Preparation",
     "import qualified " ++ rootModule,
     "$(targetFields ''" ++ root ++ " " ++ show [Text.unpack field | CollectionDecl _ field _ <- collections] ++ ")"])
  writeFile (directory </> "Evolution.hs") (unlines
    ["module Kyyn.Workspace.Evolution (module Kyyn.Evolution, module Preparation, Evolution, TargetEdits, prepare, edit, identityEvolution) where",
     "import Kyyn.Evolution hiding (Evolution, TargetEdits, prepare, edit, identityEvolution)",
     "import Kyyn.Runtime.TargetEvolution (Evolution, TargetEdits)",
     "import qualified Kyyn.Runtime.TargetEvolution as TargetEvolution",
     "import Kyyn.Runtime.TargetEvolution as Preparation (Preparation, TargetField, readCollection, migrateCollection, renameCollection, removeCollection, removeFact, readField, migrateField, putField, renameField, removeField, readRecipeState, migrateRecipe, retireRecipe)",
     "import qualified " ++ rootModule,
     "-- | Prepare stored data and then apply recorded target edits.",
     "prepare :: Preparation " ++ root ++ " () -> TargetEdits " ++ root ++ " -> Evolution " ++ root,
     "prepare = TargetEvolution.prepare",
     "-- | Change the target KB in one recorded step.",
     "edit :: Rationale -> Edit (KnowledgeBase " ++ root ++ ") () -> TargetEdits " ++ root,
     "edit = TargetEvolution.edit",
     "identityEvolution :: Evolution " ++ root,
     "identityEvolution = TargetEvolution.identityEvolution"])
