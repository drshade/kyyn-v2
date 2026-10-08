# GitHub repository evidence

The `Repository` connector captures issues, pull requests and commits from a
GitHub.com repository. It uses Kyyn's HTTP and secret capabilities; no GitHub CLI,
Git clone or separate plugin runtime is required.

Install `first-party/github` into an evolution, then inspect its configuration:

```sh
kyyn-v2 plugin install --evolution ID first-party/github
kyyn-v2 plugin connector schema show github --evolution ID
```

Configure a named instance in the target's `plugins/config/github.dhall` using
that generated schema. `RepositoryConfig` has:

- `repositoryUrl`: `https://github.com/OWNER/REPOSITORY` (trailing slash or `.git` accepted).
- `branch`: optional commit branch override; omitted uses the repository default.
  This does not restrict which issues or PRs are fetched.
- `since`: optional initial history boundary, `YYYY-MM-DDTHH:MM:SSZ`.
  Omitted means all history. Open issues/PRs are always included, regardless of age;
  closed items use their GitHub updated timestamp, commits use GitHub's `since` filter.
- `tokenSecret`: optional name of a KB secret containing a GitHub token. Omitted
  allows public access, subject to GitHub's lower unauthenticated rate limit.

For a fine-grained token, grant repository read permissions for Contents, Issues
and Pull requests. Store the token with `kyyn-v2 secret set NAME`; never put it in
the committed configuration. There is no interactive login flow.

After accepting the evolution:

```sh
kyyn-v2 evidence fetch github project
kyyn-v2 evidence list github project
kyyn-v2 evidence show github project owner/repository/issues/123
```

Evidence IDs are `owner/repository/issues/NUMBER`, `.../pulls/NUMBER`, or
`.../commits/SHA`. The `item`, `issue`, `pullRequest` and `commit` methods all take
an evidence ID. Each item includes its GitHub URL as an external reference.

Issues include Markdown bodies and conversation. PRs additionally include draft,
merge and branch information and review summaries. Inline review threads are not
captured. Commits include their full message, Git author/committer identities and
timestamps, parents and changed paths, including rename origins. `filesComplete`
is false at GitHub's 3,000-file response ceiling (conservatively including exactly
3,000). Patch fields returned by the API are discarded, not stored as evidence.

Fetch refreshes mutable discussions and emits only changed evidence. Known commit
SHAs do not refetch commit details. Mutable discussions are deliberately reread so
comment/review edits are not lost through reliance on a parent timestamp. Large
repositories may require many API requests; use a token and a suitable initial
date. A failed or rate-limited fetch publishes nothing; retry after correcting the
problem. Pagination is followed, including commit file-list pagination.

There is no automatic expiration and no inferred deletion. Closing or merging is
an update; an item disappearing from a listing or branch does not remove captured
evidence. Changing the repository, branch or date does not clear prior captures;
explicitly clear/refetch when you want to replace that scope. Existing commit
payloads are immutable captures; restoring a truncated commit requires clear/refetch.

For code investigation, use the recorded SHA with ordinary Git tooling. This plugin
does not mirror source code, fetch diffs for inspection, or implement a Git workspace.
