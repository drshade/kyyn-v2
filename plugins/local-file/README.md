# Local files

The `Folder` source connector captures regular UTF-8 text files. Configure an
absolute `directory` and whether to read child directories with `recursive`.
Symbolic links and non-UTF-8 files are unsupported; a failed fetch publishes no batch.

Evidence IDs are relative paths. Changing a file produces an update; adding or
removing a path produces an addition or removal. Unchanged files are omitted.
Source references are absolute file paths, and payloads contain the captured text.
The plugin's fingerprint combines the source path with the host-provided content
digest, so changing either produces an update. Changing the configured directory
retains relative IDs; matching files at a new source path therefore update their
references too.

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

Discover the exact configuration type before writing it:

```sh
kyyn-v2 --kb /path/to/kb plugin connector schema show local-file --evolution 000001-add-plugin
kyyn-v2 --kb /path/to/kb plugin connector list local-file --evolution 000001-add-plugin
```

Evolution checking validates every configured instance before acceptance. Once
the evolution is checked, ready and accepted, fetch its configured instance:

```sh
kyyn-v2 --kb /path/to/kb evidence fetch local-file documents
kyyn-v2 --kb /path/to/kb evidence history list local-file documents
kyyn-v2 --kb /path/to/kb evidence change list local-file documents --since FETCH
```

Omit `--since` to list all retained change markers. History and changes return
identifiers and summaries; plugin reads use the latest captured document contents.
Fetches are checkout-local Dhall data, not Git commits;
they do not change accepted facts. A draft configuration cannot acquire evidence.
