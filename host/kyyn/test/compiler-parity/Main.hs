module Main where

import Kyyn.Runtime.SchemaMetadata (encodeMetadata)
import Kyyn.Types.SchemaMetadata

main :: IO ()
main = either fail putStrLn (encodeMetadata (SchemaMetadata [] [] []))
