-- Pure SDK fact/recipe edits. Target composition and observations are exercised
-- in TargetEvolutionTests, including projection and failure isolation.
module EvolutionCore (main) where
import qualified EditTests
import qualified KnowledgeBaseTests
import qualified RecipeTests
import qualified RecipeEditTests
main :: IO ()
main = EditTests.main >> KnowledgeBaseTests.main >> RecipeTests.main >> RecipeEditTests.main
