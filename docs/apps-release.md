# zsetup-scripts apps release

`scripts/publish-apps.py` is the only production coordinator for the complete
`apps/` business release. It packages the literal repository `apps/` directory
and fixes its public destination to:

```text
BINARY_ROOT/zsetup-scripts/apps
```

The caller supplies the SSH server and that server's absolute `binary` root as
separate deployment data. The script never accepts an arbitrary public apps
destination, so it cannot map `apps/` directly onto `/binary/` or overwrite
existing `/binary/zsetup`, `/binary/ddnsto` or other product namespaces.

## Prepare and review

DDNSTO is maintained in `sources/ddnsto/` (including app.json). Build it with
`scripts/build.py` before preparation. Only its runtime outputs enter
`apps/ddnsto/`; templates, README and review.json must stay outside the public
tree. The coordinator still packages literal apps and discovers DDNSTO identity
from its external manifest. Servers do not need sources or build tools.

Preparation is local and read-only with respect to servers:

```sh
python3 -B scripts/publish-apps.py prepare
python3 -B scripts/publish-apps.py plan \
  --server SSH_CONFIG_HOST \
  --binary-root /ABSOLUTE/WEB/ROOT/binary
```

It requires generated entries/configuration and every `apps/SHA256SUMS` byte to
match a clean committed `apps/` tree. The immutable review bundle is written to
`dist/apps-releases/RELEASE_ID/`; `release.json` records the source commit, ten
applications, Linux/Windows record counts and the fixed public subpath. The
release ID is the SHA256 of `apps/SHA256SUMS`.

`plan` does not connect to the server. Review its `public_apps` value and exact
release ID before authorizing a mutation.

## Publish

After explicit production authorization, use the exact ID printed by prepare:

```sh
python3 -B scripts/publish-apps.py publish \
  --server SSH_CONFIG_HOST \
  --binary-root /ABSOLUTE/WEB/ROOT/binary \
  --approve RELEASE_ID
```

The coordinator uses strict, noninteractive SSH host-key checking and performs:

1. upload the complete reviewed release to a private, release-ID directory;
2. stage only immutable version files under `zsetup-scripts/apps`;
3. verify those bytes through every HTTPS source configured by the candidate;
4. snapshot and activate mutable entries, configs and `SHA256SUMS`;
5. verify every server byte and every file through every HTTPS source.

Activation retires files recorded by the previous managed `SHA256SUMS` when they
are absent from the new candidate. Each retired byte is digest-checked and
snapshotted before deletion, and rollback restores it. Candidate version files
remain immutable. Mutable rollback state is kept by the bundled transaction.
If final CDN verification fails, the script reports failure and retains the
state for inspection; it does not hide a possibly active release by silently
claiming success.

The stages can also be operated separately. `stage` uploads, stages and checks
all immutable mirror bytes; if CDN synchronization needs more time,
`verify-staged` safely repeats only that read-only check. `activate`, `verify`
and `rollback` complete the remaining lifecycle. Every mutating action requires
the exact release ID via `--approve`; both verify actions are read-only. Run each
command's `--help` for its required arguments. `scripts/publish.sh` is an
internal server transaction bundled into the release and is not the production
entry point.

Connection aliases, credentials, physical server inventory and rollout
authorization remain outside `apps/`. Product packages remain owned by their
existing `/binary/APP/` release processes and must be present before the apps
release is activated.

## DDNSTO console resources

The complete tree also contains generated `_sites/run.ddnsto.com/` runtime
content (recommendations, digest-addressed bodies and AI guide).
Run `scripts/build.py` before reviewing and committing; `--check` rejects drift.
These files are not a separate deployment or an upload from an old `dist/`.
Both the coordinator and server transaction stage digest-addressed bodies and
guide versions before activating mutable entries, and retain them on rollback.
Ops maps `run.ddnsto.com` paths to this DDNSTO subtree, preserving the suffix;
see [the complete mapping](ddnsto-install-deployment.md).
DDNSTO standard entries use recommendation wrappers. The historical native
bootstrap remains at `ddnsto-install.sh`; native index selectors remain unchanged.
