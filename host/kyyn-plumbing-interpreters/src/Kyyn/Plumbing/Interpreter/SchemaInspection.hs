{-# LANGUAGE GADTs, OverloadedStrings, OverloadedRecordDot #-}
module Kyyn.Plumbing.Interpreter.SchemaInspection (runSchemaInspection) where

import Control.Monad.Trans.Except (ExceptT(..), runExceptT, throwE)
import Control.Monad (unless)
import Effectful (Eff, (:>))
import Effectful.Dispatch.Dynamic (interpret)
import Kyyn.Domain.Diagnostic (errorDiagnostic)
import Kyyn.Domain.Guest (checkedEntries)
import Kyyn.Types.Guest (GuestEntry(..))
import Kyyn.Plumbing.Capability.SchemaInspection
import Kyyn.Plumbing.Capability.GuestCompilation
import Kyyn.Plumbing.Capability.GuestInspection

runSchemaInspection :: (GuestCompilation :> es, GuestInspection :> es)
  => Eff (SchemaInspection : es) a -> Eff es a
runSchemaInspection = interpret $ \_ (InspectSchema source) -> runExceptT $ do
  program <- ExceptT (compileGuest (schemaSources source))
  described <- ExceptT (describeGuest program)
  case checkedEntries described of
    [ContractEntry "root" schema] -> do
      let captured = map fst (sourceFiles (schemaSources source))
      unless (all (`elem` captured) schema.loadedSources)
        (throwE [errorDiagnostic "guest.schema-source" "Schema description refers to a source outside the captured build"])
      pure schema
    _ -> throwE [errorDiagnostic "guest.schema" "Schema discovery did not return exactly the selected root contract"]
