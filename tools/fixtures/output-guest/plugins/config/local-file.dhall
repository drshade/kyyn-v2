let Connector = < Files : Integer | Options : Integer | State : Integer | StateOptions : Integer | Writer : Integer >
in [ { name = "reader", binding = "files", connector = Connector.Files +10 }
   , { name = "writer", binding = "writer", connector = Connector.Writer +10 } ]
