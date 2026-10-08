{-# LANGUAGE OverloadedStrings #-}
module GitHub.Config (validate, repository, validSince) where

import Data.Char (isAscii, isAlphaNum, isDigit)
import qualified Data.Text as Text
import Data.Text (Text)
import GitHub.Types
import Kyyn.Validation

repository :: Text -> Either Text (Text,Text)
repository input = do
  path <- maybe (Left "Expected https://github.com/OWNER/REPOSITORY") Right
    (Text.stripPrefix "https://github.com/" input)
  let trimmed = Text.dropWhileEnd (== '/') path
      bare = maybe trimmed id (Text.stripSuffix ".git" trimmed)
      component value = not (Text.null value) && value /= "." && value /= ".."
        && Text.all (\c -> isAscii c && (isAlphaNum c || c `elem` ("-_." :: String))) value
  case Text.splitOn "/" bare of
    [owner,name] | component owner && component name -> Right (owner,name)
    _ -> Left "Expected a repository URL, without a branch, query or fragment"

-- | One UTC spelling keeps the initial boundary and GitHub timestamps comparable.
validSince :: Text -> Bool
validSince input = case Text.unpack input of
  [a,b,c,d,'-',e,f,'-',g,h,'T',i,j,':',k,l,':',m,n,'Z']
    | all (\x -> isAscii x && isDigit x) [a,b,c,d,e,f,g,h,i,j,k,l,m,n] ->
      let year = read [a,b,c,d] :: Int
          month = read [e,f] :: Int
          day = read [g,h] :: Int
          leap = year `mod` 4 == 0 && (year `mod` 100 /= 0 || year `mod` 400 == 0)
          days = [31,if leap then 29 else 28,31,30,31,30,31,31,30,31,30,31]
      in year >= 1970 && year <= 2099 && month >= 1 && month <= 12
        && day >= 1 && day <= days !! (month-1)
        && (read [i,j] :: Int) <= 23 && (read [k,l] :: Int) <= 59 && (read [m,n] :: Int) <= 59
  _ -> False

validate :: RepositoryConfig -> ValidationReport
validate (RepositoryConfig url branch since secret) = ValidationReport $
  [errorDiagnostic "github.repository" problem | Left problem <- [repository url]] ++
  [errorDiagnostic "github.branch" "Branch override must not be blank" | Just value <- [branch], Text.null (Text.strip value)] ++
  [errorDiagnostic "github.since" "Use a valid UTC timestamp YYYY-MM-DDTHH:MM:SSZ (1970–2099)" | Just value <- [since], not (validSince value)] ++
  [errorDiagnostic "github.secret" "Token secret name must not be blank" | Just value <- [secret], Text.null (Text.strip value)]
