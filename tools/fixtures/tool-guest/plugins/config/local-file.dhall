let Connector = < Files : Integer | Options : Integer | State : Integer | StateOptions : Integer | Updates : Integer | Writer : Integer >
in [ { name = "reader", binding = "files", connector = Connector.Files +10 }
   , { name = "updates", binding = "updates", connector = Connector.Updates +10 } ]
