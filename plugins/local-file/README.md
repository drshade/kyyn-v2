# Local files

The `Folder` source connector captures regular UTF-8 text files. Configure an
absolute `directory` and whether to read child directories with `recursive`.
Symbolic links and non-UTF-8 files are unsupported; a failed fetch publishes no batch.

Evidence IDs are relative paths. Changing a file produces an update; adding or
removing a path produces an addition or removal. Unchanged files are omitted.
Source references are absolute file paths, and payloads contain the captured text.
The host-provided fingerprint covers the source path and file contents, so
changing either produces an update. Changing the configured directory
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
kyyn-v2 --kb /path/to/kb evidence list local-file documents
kyyn-v2 --kb /path/to/kb evidence show local-file documents notes.txt
```

Listing returns current identifiers and fingerprints with the latest-fetch summary;
show and plugin reads use the latest captured document contents.
Fetches are checkout-local Dhall data, not Git commits;
they do not change accepted facts. A draft configuration cannot acquire evidence.

Discover and read a fetched file:

```sh
kyyn-v2 --kb /path/to/kb plugin connector method list local-file documents
kyyn-v2 --kb /path/to/kb plugin connector method show local-file documents content
kyyn-v2 --kb /path/to/kb plugin connector method execute local-file documents content --input '"notes.txt"'
```

The ID is the path relative to the configured directory. `content` returns the
latest fetched UTF-8 text, not the live file. Fetch again to refresh it. A missing
ID is an error. Inputs and human-readable results are Dhall; `--json` returns
structural JSON. List/show also accept `--evolution ID` to inspect a draft target;
execution uses only accepted configuration.

To discard one instance's local evidence and fetch it again:

```sh
kyyn-v2 --kb /path/to/kb evidence clear local-file documents
kyyn-v2 --kb /path/to/kb evidence fetch local-file documents
```
