# Project Rules

## Public Git history

- Local `master` preserves the repository's private development history. Never push local `master` to any public remote.
- Public changes must be published through `public-master`, which tracks `origin/master` and intentionally has history unrelated to local `master`.
- Before transferring changes to `public-master`, ensure the public snapshot contains no private domains, local paths, device names, credentials, screenshots, or other personal/deployment data.
- Never push historical local tags (including `v1.0.0`) or private-history refs to the public remote unless the user explicitly authorizes exposing them.
- Do not merge or rebase local `master` into `public-master`. Synchronize only the reviewed, sanitized file snapshot or equivalent selected changes, then validate the resulting public diff before pushing.
