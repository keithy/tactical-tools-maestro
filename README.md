# tactical-tools-maestro

Adaptation of [`feenkcom/gtoolkit-maestro-rs`](https://github.com/feenkcom/gtoolkit-maestro-rs) — a set of tools to build, release, deploy and test Glamorous Toolkit.

## mise tasks

This repo uses [mise](https://mise.jdx.dev/) for task management. Tasks live in `mise/tasks/` and are auto-discovered by mise.

### install-oils

Installs [Oils](https://oils.pub/) (the shell, formerly called "Oil") into a user-local prefix (default `~/.local`, no sudo required).

```sh
mise run install-oils              # install the latest version
mise run install-oils 0.36.0       # install a specific version
mise run install-oils --force      # reinstall even if already present
mise run install-oils --prefix /tmp/test  # install to a different location
mise run oils:install              # alias
```

The task:

- Probes the [oils.pub releases page](https://oils.pub/releases.html) for the latest version
- Downloads the matching `oils-for-unix-<version>.tar.gz` source tarball
- Builds with the bundled `configure` + `_build/oils.sh` + `./install`
- Installs into `${prefix}/bin/` as `ysh`, `osh`, and `oils-for-unix` symlinks
- Runs the smoke tests from Oils' [INSTALL.html](https://oils.pub/release/latest/doc/INSTALL.html):
  - `osh -c 'echo hi'` — POSIX shell behaviour
  - `ysh -c 'json write ({x: 42})'` — YSH structured-data support

The smoke tests fail the task with a clear error if the install is broken
in a way that produces a non-functional binary (e.g. wrong symlink target,
missing JSON support).

The task is idempotent: re-running with the same version exits without
rebuilding.

## See also

- [Glamorous Toolkit](https://gtoolkit.org/) — what Oils+YSH+GT are for
- [gtoolkit-vm](https://github.com/feenkcom/gtoolkit-vm) — the Glamorous Toolkit VM
- [gtoolkit-maestro-rs](https://github.com/feenkcom/gtoolkit-maestro-rs) — the upstream Rust orchestrator