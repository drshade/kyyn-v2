module Annotations (metadata, emptyMetadata) where

import Kyyn.Schema

metadata :: SchemaMetadata
metadata = SchemaMetadata [] [] [CollectionDecl "items-é" "items" []]

emptyMetadata :: SchemaMetadata
emptyMetadata = SchemaMetadata [] [] []
