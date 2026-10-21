{-# LANGUAGE OverloadedStrings #-}
module MicrosoftGraph.Files.Config (validate, login, matches) where
import Data.Text (Text)
import qualified Data.Text as Text
import Kyyn.Validation
import Kyyn.Plugin.Host (PluginLogin, LoginError)
import MicrosoftGraph.Files.Types
import MicrosoftGraph.Config (authentication)
import qualified MicrosoftGraph.Auth as Auth

validate :: FilesConfig -> ValidationReport
validate (FilesConfig auth scope path globs) = ValidationReport $
  authentication auth "files" <>
  [errorDiagnostic "graph.files-scope" "Specify a site ID and library ID/name, a OneDrive user ID/email, or an HTTPS sharing URL." | invalidScope scope] <>
  [errorDiagnostic "graph.files-path" "Use a relative slash-separated file/folder path without empty, dot or parent segments; empty selects the root." |
    not (Text.null path) && invalidPath path] <>
  [errorDiagnostic "graph.files-glob" "Include globs must be nonempty relative paths without dot/parent segments or backslashes." |
    any (\g -> Text.null g || invalidPath g) globs]
  where
    invalidScope (SiteLibrary site library) = any (Text.null . Text.strip) [site,library]
    invalidScope (OneDrive user) = Text.null (Text.strip user)
    invalidScope (SharedUrl url) = not ("https://" `Text.isPrefixOf` url) || Text.length url <= 8
    invalidPath value = Text.any (== '\\') value || any (`elem` ["",".",".."]) (Text.splitOn "/" value)

login :: FilesConfig -> PluginLogin (Either LoginError ())
login (FilesConfig auth _ _ _) = Auth.login auth

-- ** spans path segments; a **/ prefix also matches zero directories.
matches :: [Text] -> Text -> Bool
matches [] _ = True
matches patterns path = any (\glob -> match (Text.unpack glob) (Text.unpack path)) patterns
  where
    match [] value = null value
    match ('*':'*':'/':rest) value = match rest value || case break (== '/') value of
      (_, '/':remaining) -> match ('*':'*':'/':rest) remaining
      _ -> False
    match ('*':'*':rest) value = match rest value || descend ('*':'*':rest) value
    match ('*':rest) value = match rest value || case value of
      c:cs | c /= '/' -> match ('*':rest) cs
      _ -> False
    match ('?':rest) (c:cs) = c /= '/' && match rest cs
    match (p:ps) (c:cs) = p == c && match ps cs
    match _ _ = False
    descend glob (_:cs) = match glob cs
    descend _ [] = False
