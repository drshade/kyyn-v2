-- Inspect real closed-flow signatures with the pinned MicroHs adapter and generated
-- tool/collection bindings. No provider calls, proposal execution or persistence.
{-# LANGUAGE OverloadedStrings #-}
module Main (main) where

import Control.Monad (forM_, unless)
import qualified Data.ByteString as Bytes
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import Kyyn.Domain.Contract
import Kyyn.Domain.DataType
import Kyyn.Domain.FileTree (files)
import Kyyn.Domain.Path (relativeName)
import Kyyn.Domain.Recipe (RecipeSignature(..))
import Kyyn.Types.SchemaMetadata (SchemaMetadata(..), CollectionDecl(..))
import Kyyn.Plumbing.Protocol.Evolution (evolutionBindings)
import Kyyn.Plumbing.Protocol.Tool (toolBindings)
import Kyyn.MicroHs.Inspection (inspectRecipeSignature, inspectRecipeExports)
import System.Directory (createDirectoryIfMissing)
import System.Environment (getEnv)
import System.FilePath ((</>), takeDirectory)
import System.IO.Temp (withSystemTempDirectory)

main :: IO ()
main = withSystemTempDirectory "kyyn-recipe-signatures-" $ \temporary -> do
  repo <- getEnv "KYYN_TEST_ROOT"
  compiler <- getEnv "KYYN_TEST_TOOLCHAIN"
  let state = Algebraic "Schema.Review" [] [Constructor "Schema.Review" [(Just "seen",ListType StringType)]]
      fact = Algebraic "Kyyn.Types.Fact.Fact" [StringType]
        [Constructor "Kyyn.Types.Fact.Fact" [(Nothing,sdkFactIdType),(Nothing,StringType)]]
      root = Algebraic "Schema.Root" [] [Constructor "Schema.Root" [(Just "items",ListType fact)]]
  contract <- right (checkContract root (SchemaMetadata [] [] [CollectionDecl "items" "items" []]) >>= checkRootLayout)
  workspace <- right (evolutionBindings contract contract)
  tools <- right (toolBindings [] [])
  forM_ (files workspace ++ tools) $ \(path,bytes) -> do
    let destination = temporary </> relativeName path
    createDirectoryIfMissing True (takeDirectory destination)
    Bytes.writeFile destination bytes
  Bytes.writeFile (temporary </> "Schema.hs") (Text.encodeUtf8 (Text.unlines
    ["module Schema where", "import Kyyn.Types.Fact (Fact)",
     "data Root = Root { items :: [Fact String] }", "data Review = Review { seen :: [String] }"]))
  Bytes.writeFile (temporary </> "Flows.hs") (Text.encodeUtf8 (Text.unlines
    ["module Flows where", "import Schema", "import Kyyn.Agentic (Flow)",
     "import Kyyn.Recipe", "import Kyyn.Workspace.FactEdits (RootEdit)",
     "review :: Flow (RecipeInput Root String Review) (RecipeProposal RootEdit Review)",
     "review = error \"Inspection must not execute this flow\"",
     "unit :: Flow (RecipeInput Root () ()) (RecipeProposal RootEdit ())",
     "unit = error \"Inspection must not execute this flow\"",
     "wrongState :: Flow (RecipeInput Root () Review) (RecipeProposal RootEdit ())",
     "wrongState = error \"not a valid recipe\"",
     "wrongEdits :: Flow (RecipeInput Root () Review) (RecipeProposal String Review)",
     "wrongEdits = error \"not a valid recipe\"",
     "notAFlow :: RecipeInput Root () Review -> RecipeProposal RootEdit Review",
     "notAFlow = error \"not a valid recipe\""]))
  let sources = temporary : map (repo </>) ["shared/kyyn-types/src","guest/kyyn-sdk/src",
        "guest/kyyn-runtime/src","vendor/agentic/src","vendor/transformers","vendor/json"]
      inspect name = inspectRecipeSignature compiler sources ("Flows." ++ name)
  (signature,_) <- inspect "review" >>= right
  unless (signature == RecipeSignature root StringType state) (fail ("Wrong reflected flow: " ++ show signature))
  (unit,_) <- inspect "unit" >>= right
  unless (unit == RecipeSignature root UnitType UnitType) (fail "Unit input/state did not reflect")
  (exports,_) <- inspectRecipeExports compiler sources "Flows" >>= right
  unless (length exports == 2 && lookup "review" exports == Just signature && lookup "unit" exports == Just unit)
    (fail ("Recipe definition discovery included incompatible signatures: " ++ show exports))
  forM_ ["wrongState","wrongEdits","notAFlow"] $ \name -> do
    result <- inspect name
    case result of
      Left _ -> pure ()
      Right _ -> fail ("Accepted invalid recipe: " ++ name)
  putStrLn "Closed flow request/state types reflect correctly; invalid signatures are refused without execution."

right :: Show e => Either e a -> IO a
right = either (fail . show) pure
