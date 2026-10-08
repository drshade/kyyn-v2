module MicrosoftGraph.Timestamp (timestamp, daysBefore) where

import Data.Char (isDigit)
import Data.Ratio ((%))
import qualified Data.Text as Text

-- | Calendar date/time with seconds, optional fraction, and Z or a numeric offset.
timestamp :: Text.Text -> Either Text.Text Rational
timestamp = either (Left . Text.pack) Right . parseTimestamp . Text.unpack

-- | Preserve the UTC time of day while shifting a host invocation date backwards.
daysBefore :: Integer -> Text.Text -> Either Text.Text Text.Text
daysBefore count input = do
  _ <- timestamp input
  if count < 0 || not (Text.isSuffixOf (Text.pack "Z") input) then Left (Text.pack "Expected UTC timestamp and nonnegative days") else pure ()
  let value = Text.unpack input
      year = read (take 4 value)
      month = read (take 2 (drop 5 value))
      day = read (take 2 (drop 8 value))
      shift 0 date = Right date
      shift n (y,m,d) | d > 1 = shift (n-1) (y,m,d-1)
                      | m > 1 = shift (n-1) (y,m-1,monthDays y (m-1))
                      | y > 1 = shift (n-1) (y-1,12,31)
                      | otherwise = Left (Text.pack "Backfill precedes supported dates")
      monthDays y m = [31,if y `mod` 4 == 0 && (y `mod` 100 /= 0 || y `mod` 400 == 0) then 29 else 28,31,30,31,30,31,31,30,31,30,31] !! (m-1)
      pad width n = let digits = show (n :: Int) in replicate (width - length digits) '0' ++ digits
  (y,m,d) <- shift count (year,month,day)
  pure (Text.pack (pad 4 y ++ "-" ++ pad 2 m ++ "-" ++ pad 2 d ++ drop 10 value))

parseTimestamp :: String -> Either String Rational
parseTimestamp input = do
  (year,r1) <- digits 4 input
  (month,r2) <- separator '-' r1 >>= digits 2
  (day,r3) <- separator '-' r2 >>= digits 2
  (hour,r4) <- separator 'T' r3 >>= digits 2
  (minute,r5) <- separator ':' r4 >>= digits 2
  (second,r6) <- separator ':' r5 >>= digits 2
  (fraction,zone) <- case r6 of
    '.':rest -> let (part,end) = span asciiDigit rest in
      if null part then bad else Right (read part % (10 ^ length part),end)
    _ -> Right (0,r6)
  offset <- case zone of
    "Z" -> Right 0
    sign:rest | sign == '+' || sign == '-' -> do
      (hours,more) <- digits 2 rest
      (minutes,end) <- separator ':' more >>= digits 2
      if not (null end) || hours > 23 || minutes > 59 then bad
        else Right ((if sign == '+' then 1 else -1) * (hours * 60 + minutes))
    _ -> bad
  let leap = year `mod` 4 == 0 && (year `mod` 100 /= 0 || year `mod` 400 == 0)
      months = [31,if leap then 29 else 28,31,30,31,30,31,31,30,31,30,31]
  if year < 1 || month < 1 || month > 12 || day < 1 || day > months !! fromInteger (month - 1)
      || hour > 23 || minute > 59 || second > 59 then bad else do
    let y = year - 1
        days = 365*y + y `div` 4 - y `div` 100 + y `div` 400 + sum (take (fromInteger (month - 1)) months) + day - 1
    Right (fromInteger (days * 86400 + hour * 3600 + minute * 60 + second - offset * 60) + fraction)
  where
    bad :: Either String a
    bad = Left "Expected a valid YYYY-MM-DDTHH:MM:SS[.fraction]Z or numeric-offset timestamp"
    asciiDigit :: Char -> Bool
    asciiDigit c = c <= '9' && isDigit c
    digits :: Int -> String -> Either String (Integer,String)
    digits count value = let (part,rest) = splitAt count value in
      if length part == count && all asciiDigit part then Right (read part :: Integer,rest) else bad
    separator :: Char -> String -> Either String String
    separator wanted (actual:rest) | wanted == actual = Right rest
    separator _ _ = bad
