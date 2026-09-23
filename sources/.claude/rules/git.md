# Git policy

`git` is allowlisted in every project: read-only inspection and safe local ops
are allowed; history/remote writes are not — no commit, merge, push, pull,
reset, or `config`/`remote` writes. A denied call returns
`git-allowlist: "git <sub>" is not in the allowlist`.

For the exact allowed set, read `$CLAUDE_GIT_ALLOWLIST_CONFIG` — the single
source of truth — rather than guessing. You can inspect and stage but not
commit/push: when a change is ready, describe it and hand the commit/push to a
plain terminal.
```
