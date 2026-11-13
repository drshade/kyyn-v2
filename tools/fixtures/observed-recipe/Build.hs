-- Compile a test entry after the ordinary guest builder has generated its SDK.
-- Reuse the builder's language/package selection; no product test switch.
import Kyyn.Build.Language (guestLanguageFlags)
import Kyyn.Build.Inspection (packageOptions)
import System.Environment (getArgs)
import System.Directory (createDirectoryIfMissing)
import System.Process (callProcess, readProcess)

main :: IO ()
main = do
  [entry,destination] <- getArgs
  libdir <- single <$> readProcess "ghc" ["--print-libdir"] ""
  runtime <- single <$> readProcess "ghc-pkg" ["field","z-kyyn-sdk-z-runtime","id","--simple-output"] ""
  packages <- packageOptions libdir
  createDirectoryIfMissing True ".kyyn-generated/observed-test"
  callProcess "ghc" (["--make"] ++ guestLanguageFlags ++ packages ++
    ["-package-id",runtime,"-isrc","-i.kyyn-generated","-iplugins/packages/local-file/source/src",
     "-odir",".kyyn-generated/observed-test","-hidir",".kyyn-generated/observed-test",
     "-main-is","ObservedRecipeEntry.main",entry,"-o",destination])
  where
    single text = case lines text of [line] -> line; _ -> error "Expected one compiler/package path"
