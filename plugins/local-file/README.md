# Local files

This package exercises plugin source installation. Its entry exports a description;
file reading, writing and connector registration are not implemented yet.

From a committed Kyyn checkout, install it into an existing evolution's target:

```sh
kyyn-v2 --kb /path/to/kb plugin install --evolution 000001-add-plugin --from ./plugins/local-file
```
