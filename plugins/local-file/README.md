# Local files

The `Folder` source connector captures regular UTF-8 text files. Configure an
absolute `directory` and whether to read child directories with `recursive`.
Symbolic links and non-UTF-8 files are unsupported; a failed fetch publishes no batch.

Evidence IDs are relative paths. Changing a file produces an update; adding or
removing a path produces an addition or removal. Unchanged files are omitted.
Source references are absolute file paths, and payloads contain the captured text.
Changing the configured directory retains relative IDs, so matching paths are
compared with the preceding snapshot, including their source references.

`LocalFile.Plugin.connectors` advertises the Haskell config/payload types, fetch
function and pure config validator. The host derives contracts and generated
bindings; authored plugin code contains no filesystem or transport IO.

From a committed Kyyn checkout, install it into an existing evolution's target:

```sh
kyyn-v2 --kb /path/to/kb plugin install --evolution 000001-add-plugin --from ./plugins/local-file
```

Named instance configuration belongs in the evolution target's
`plugins/config/local-file.dhall`, for example:

```dhall
let Connector = < Folder : { directory : Text, recursive : Bool } >
in [ { name = "documents"
     , binding = "documents"
     , connector = Connector.Folder
         { directory = "/path/to/documents", recursive = True }
     } ]
```

Evolution checking validates every configured instance before acceptance. The
native registration proof exercises real configured fetches; CLI fetch commands
are the next integration step.
