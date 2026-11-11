module MicrosoftGraph.Timestamp (timestamp, daysBefore) where

import Data.Scientific (scientific)
import qualified Data.Text as Text
import Data.Time

-- | Calendar date/time with seconds, optional fraction, and Z or a numeric offset.
-- Keep arbitrary provider fraction precision; ZonedTime itself uses picoseconds.
timestamp :: Text.Text -> Either Text.Text Rational
timestamp input = do
  (value,fraction) <- parseTimestamp input
  pure (toRational (diffUTCTime (zonedTimeToUTC value) (UTCTime firstDay 0)) + fraction)

-- | Preserve the UTC time of day while shifting a host invocation date backwards.
daysBefore :: Integer -> Text.Text -> Either Text.Text Text.Text
daysBefore count input = do
  (value,_) <- parseTimestamp input
  if count < 0 || not (Text.isSuffixOf "Z" input)
    then Left "Expected UTC timestamp and nonnegative days" else pure ()
  let shifted = addDays (negate count) (localDay (zonedTimeToLocalTime value))
  if shifted < firstDay then Left "Backfill precedes supported dates" else
    pure (Text.pack (formatTime defaultTimeLocale "%04Y-%m-%d" shifted) <> Text.drop 10 input)

firstDay :: Day
firstDay = fromGregorian 1 1 1

parseTimestamp :: Text.Text -> Either Text.Text (ZonedTime,Rational)
parseTimestamp input = do
  let (clock,rest) = splitAt 19 (Text.unpack input)
      (digits,zone) = case rest of '.':more -> span asciiDigit more; _ -> ("",rest)
      normalizedZone = if zone `elem` ["Z","-00:00"] then "+00:00" else zone
      whole = clock ++ normalizedZone
      format = "%Y-%m-%dT%H:%M:%S%Ez"
  if take 1 rest == "." && null digits then bad else pure ()
  value <- maybe bad Right (parseTimeM False defaultTimeLocale format whole)
  let local = zonedTimeToLocalTime value
      (year,_,_) = toGregorian (localDay local)
  -- Enforce the provider grammar rather than accepting the time parser's wider
  -- set of spellings, leap seconds or out-of-range timezone offsets.
  if length clock /= 19 || year < 1 || year > 9999 || todSec (localTimeOfDay local) >= 60 ||
      abs (timeZoneMinutes (zonedTimeZone value)) > 1439 ||
      formatTime defaultTimeLocale "%04Y-%m-%dT%H:%M:%S%Ez" value /= whole then bad else
    pure (value, if null digits then 0 else toRational (scientific (read digits) (negate (length digits))))
  where
    asciiDigit c = c >= '0' && c <= '9'
    bad = Left "Expected a valid YYYY-MM-DDTHH:MM:SS[.fraction]Z or numeric-offset timestamp"
