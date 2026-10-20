# Salesforce

`Query` runs a saved SOQL SELECT and captures one evidence item per returned record.
Every fetch runs the whole query. Changed records update evidence; records no longer
returned leave the capture. This does not delete curated KB facts or prove that a
record was deleted in Salesforce.

Configuration and usage examples will be completed with the installed CLI journey.
