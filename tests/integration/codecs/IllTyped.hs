module IllTyped where
data Root = Root { name :: String }
broken :: Bool
broken = "not a boolean"
