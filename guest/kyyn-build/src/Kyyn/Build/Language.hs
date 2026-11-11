module Kyyn.Build.Language (guestLanguageFlags) where

-- Shared by code generation, type inspection and source inventory.
guestLanguageFlags :: [String]
guestLanguageFlags = map ("-X" ++)
  [ "GHC2024"
  , "OverloadedStrings"
  , "DeriveAnyClass"
  , "OverloadedRecordDot"
  , "DuplicateRecordFields"
  , "NoFieldSelectors"
  , "RecordWildCards"
  , "BlockArguments"
  , "MultiWayIf"
  ]
