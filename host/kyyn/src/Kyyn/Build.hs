{-# LANGUAGE CPP #-}
module Kyyn.Build (guestTemplateDirectory) where

guestTemplateDirectory :: Maybe FilePath
#ifdef KYYN_TEMPLATE_DIRECTORY
guestTemplateDirectory = Just KYYN_TEMPLATE_DIRECTORY
#else
guestTemplateDirectory = Nothing
#endif
