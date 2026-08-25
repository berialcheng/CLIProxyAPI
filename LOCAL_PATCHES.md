# Local Patch Maintenance

This fork keeps upstream source and locally maintained behavior on separate
branches. The goal is to make every local customization easy to review,
rebase, test, release, and eventually remove.

## Branch invariants

- `main` is a fast-forward-only mirror of `upstream/main`. Never commit local
  changes to it.
- `local/main` is the deployable local patch stack.
- `patch/<slug>` is for developing one local customization.
- `sync/vX.Y.Z` is a disposable candidate used to rebase the patch stack onto
  a tagged upstream release.
- `vX.Y.Z-local.N` is an immutable local release and rollback anchor. Reset
  `N` to `1` for a new upstream version and increment it for changes on the
  same upstream version.
- Never use `git push --tags`; push one reviewed local release tag explicitly.

The `upstream` remote is fetch-only in the local repository, and its fetch
refspec intentionally tracks only `upstream/main`.

## Active patches

### `model-catalog-overrides`

- Status: active
- First local release: `v7.2.125-local.1`
- Commit subject: `feat(config): add local model catalog overrides`
- Configuration surface: top-level `model-overrides`
- Purpose: override advertised model metadata, including the Codex OAuth and
  static catalog context window, without changing upstream request routing.
- Upstream tracking:
  - <https://github.com/router-for-me/CLIProxyAPI/issues/3744>
  - <https://github.com/router-for-me/CLIProxyAPI/issues/4476>
  - <https://github.com/router-for-me/CLIProxyAPI/issues/4728>
- Required focused tests:
  - `./internal/config`
  - `./internal/registry`
  - `./internal/client/codex/models`
  - `./internal/watcher`
  - `./cmd/server`
- Removal condition: upstream provides an equivalent configuration path for
  OAuth/static/remote-catalog models, including hot-reload, cache invalidation,
  and clearing an override back to the upstream value.
- Known boundaries:
  - Home-mode model payloads do not use the registry overlay.
  - Override keys match the final visible model ID after alias/prefix handling.

Keep the implementation and its tests in one logical patch. If upstream gains
equivalent behavior, remove this patch during the next `sync/vX.Y.Z` rebase
instead of carrying duplicate behavior.

## Upgrade workflow

1. Inspect the new upstream `main` release and changelog. Do not consume
   `upstream/dev`.
2. Run `scripts/local-sync.ps1 -UpstreamTag vX.Y.Z -CheckOnly`.
3. Run `scripts/local-sync.ps1 -UpstreamTag vX.Y.Z` to fast-forward the local
   `main` and create `sync/vX.Y.Z`. The script never pushes or updates
   `local/main` automatically.
4. Resolve any rebase conflicts, then inspect the emitted `git range-diff`.
5. Run `scripts/local-build.ps1` on the candidate. Use `-FullTest` when the
   upstream Windows suite is known to be green.
6. Promote only with the exact atomic, SHA-pinned `--force-with-lease` command
   printed by the sync script.
7. Create one annotated `vX.Y.Z-local.N` tag and run
   `scripts/local-build.ps1 -Release` from that exact tag.
8. Record the executable and archive SHA-256 values in the GitHub Release or
   deployment record before replacing the service binary.

Use this comparison after rebasing to ensure the patch intent did not drift:

```powershell
git range-diff <old-upstream-base>..local/main main..sync/vX.Y.Z
```

## Build and artifact policy

- The local Windows release target is `GOOS=windows`, `GOARCH=amd64`, and
  `CGO_ENABLED=0`.
- The supported local toolchain is pinned in `scripts/local-build.ps1`.
- Build metadata uses the commit timestamp rather than wall-clock time so the
  executable inputs remain stable for the same commit and toolchain.
- Release artifacts are written below ignored `bin/local-release/` and include
  `BUILDINFO.json` plus SHA-256 checksums. ZIP entries use a fixed order and the
  commit timestamp.
- Never package `config.yaml`, `.env`, `auths/`, runtime logs, or deployed auth
  state. Only source-controlled public documentation and the executable belong
  in the archive.

The Windows upstream suite has previously contained failures unrelated to the
local patch. Focused tests and the Windows build are mandatory; a full suite is
additional evidence and must not be mislabeled as passing when upstream debt is
still present.
