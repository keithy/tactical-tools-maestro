# gt-installer-bash

A pure-bash port of [`feenkcom/gtoolkit-maestro-rs`](https://github.com/feenkcom/gtoolkit-maestro-rs)'s `gt-installer`.

The Rust binary is a `clap`-driven orchestrator that downloads the
Glamorous Toolkit VM, builds/updates a Pharo image with GT loaded, and ships
subcommands like `build`, `setup`, `start`, `test`, `package-tentative`, etc.
This project reimplements the same command surface and behaviour using only
`curl`, `unzip`, `awk`, `sed`, and `grep`, so the installer can be used in
environments where Rust isn't available.

## Quick start

```sh
curl -LsS https://raw.githubusercontent.com/keithhamilton/gt-installer-bash/main/gt-installer.sh | bash
```

The default subcommand is `local-build`, matching the Rust binary and the
shipped `scripts/installer.sh` in the original repo.

The installer reads `gtoolkit.yaml` from the current working directory as a
"what to do" recipe. If the YAML is missing, it generates a starter with
the latest versions from GitHub so you have something to edit if anything
goes wrong. **The installer never rewrites `gtoolkit.yaml` after `build` or
`setup`** — only `rename-to` / `copy-to` do, because they intentionally
mutate the image identity.

### Several YAMLs for different tasks

You can keep multiple YAMLs side-by-side and pick the one you want:

```sh
# dev.yaml, release.yaml, ci.yaml live in the project root
gt-installer --yaml dev.yaml    build --overwrite
GT_INSTALLER_YAML=release.yaml gt-installer release-build
gt-installer                    # uses ./gtoolkit.yaml in CWD
```

Lookup order: `--yaml` flag → `$GT_INSTALLER_YAML` → `./gtoolkit.yaml`.

## Requirements

- `bash` 4+
- `curl`
- `unzip`
- `zip` (only for `package-tentative` / `package-release`)

## Layout

```
gt-installer.sh          # Main entry point (bash port of `src/main.rs`)
scripts/installer.sh     # Mirror of the upstream curl-pipe installer
st/load-patches.st       # Bundled Pharo patches (mirrors src/st/load-patches.st)
st/clone-gt.st.template  # {{}}-template version of src/st/clone-gt.st
st/load-gt.st.template   # {{}}-template version of src/st/load-gt.st
test.sh                  # Smoke tests
```

## Subcommands

Each subcommand mirrors a `SubCommand` variant in `src/options.rs`:

| Rust subcommand       | Bash subcommand              |
| --------------------- | ---------------------------- |
| `local-build`         | `local-build`                |
| `release-build`       | `release-build`              |
| `build`               | `build`                      |
| `download vm`         | `download vm`                |
| `setup`               | `setup`                      |
| `copy-to`             | `copy-to`                    |
| `rename-to`           | `rename-to`                  |
| `start`               | `start`                      |
| `clean-up`            | `clean-up`                   |
| `test`                | `test`                       |
| `package-tentative`   | `package-tentative`          |
| `unpackage-tentative` | `unpackage-tentative`        |
| `package-release`     | `package-release`            |
| `run-releaser`        | `run-releaser`               |
| `print-debug`         | `print-debug`                |
| `print-gtoolkit-image-version` | `print-gtoolkit-image-version` |
| `print-gtoolkit-app-version`   | `print-gtoolkit-app-version`   |

Run `gt-installer.sh <subcommand> --help` (or just `--help`) for the global
and per-subcommand options.

## Differences vs. the Rust binary

- All Rust dependencies (`clap`, `serde_yaml`, `tokio`, `octocrab`, …) are
  replaced with POSIX tooling — there is **no JSON / YAML library** in the
  bash version. The `gtoolkit.yaml` schema is a small subset the Rust binary
  actually writes.
- Pro-VM download uses an authenticated GitHub release asset endpoint in the
  Rust crate (`feenk-download-auth-client`). The bash version performs a
  direct release-asset lookup when `FEENK_CUSTOMER_ID` / `FEENK_CUSTOMER_KEY`
  are set and `--customer-level pro` is requested. The auth dance itself is
  intentionally not reimplemented — wire up your own `curl` shim if you need
  the private asset.
- Android APK packaging uses `ndk-build` in Rust. The bash `package-release`
  subcommand refuses to target `AndroidAarch64`.
- `clap`'s `--no-quit` / `--save` / `--interactive` semantics are mapped
  directly to the underlying Pharo CLI flags.
- The Smalltalk evaluation is done by shelling out to the `GlamorousToolkit`
  CLI; output redirection to `install.log` / `install-errors.log` (as the
  Rust crate does in `SmalltalkEvaluator::stdout`/`stderr`) is currently
  inherited from the CLI's own logging behaviour rather than re-implemented.

## Testing

```sh
./test.sh
```

Tests cover syntax, CLI parsing, duration parsing, version comparison, YAML
serialization round-trip, and host platform detection.

## License

MIT. Bundled `st/load-patches.st` is © its respective authors and is
included unmodified from upstream.