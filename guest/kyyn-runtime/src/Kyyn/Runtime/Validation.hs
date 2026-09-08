module Kyyn.Runtime.Validation (encodeReport, encodeReportValue) where

import Kyyn.Types.Diagnostic
import Kyyn.Runtime.Json
import Text.JSON.Types (JSValue(JSArray))

encodeReport :: ValidationReport -> Either String String
encodeReport report = encodeReportValue report >>= printValue

encodeReportValue :: ValidationReport -> Either String JSValue
encodeReportValue (ValidationReport diagnostics)
  | any invalidPosition diagnostics = Left "Expected positive source coordinates"
  | otherwise = Right (JSArray (map encodeDiagnostic diagnostics))
  where
    invalidPosition (Diagnostic _ _ _ (Just (SourceLocation _ line column))) = line <= 0 || column <= 0
    invalidPosition _ = False
    text = encodeWith stringCodec
    optionalText = encodeWith (optionalCodec stringCodec)
    encodeDiagnostic (Diagnostic level diagnosticCode diagnosticMessage diagnosticLocation) = record
      [("severity", tagged (case level of Warning -> "Warning"; Error -> "Error") Nothing),
       ("code", text diagnosticCode), ("message", text diagnosticMessage),
       ("location", case diagnosticLocation of
          Nothing -> tagged "None" Nothing
          Just value -> tagged "Some" (Just (encodeLocation value)))]
    encodeLocation (FactLocation collection factId fieldName) = tagged "Fact" (Just (record
      [("collection", text collection), ("factId", text factId), ("field", optionalText fieldName)]))
    encodeLocation (SourceLocation file line column) = tagged "Source" (Just (record
      [("file", text file), ("line", encodeWith integerCodec line), ("column", encodeWith integerCodec column)]))
    encodeLocation (ExampleLocation example) = tagged "Example" (Just (text example))
