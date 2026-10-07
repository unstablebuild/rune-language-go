# Go language package

To install Go support in Rune, run this command in the Rune console:

```text
pkg install go
```

This package ships the Go toolchain, `gopls`, `goimports`, `dlv`, the Go
extension, and the tree-sitter grammar. The release instructions below are for
Rune maintainers.

## Release runbook

1. **Prepare the build host.** macOS builds every platform; Linux builds only
   the Linux packages, since macOS packages are signed. The
   Makefile downloads the pinned Go toolchains itself. Install `wget`, `zig`
   (it compiles the Linux tree-sitter parser), `bluectl`, and tar (GNU `gtar`
   on macOS). macOS also needs the Xcode command line tools, the Developer ID
   signing identity. Rune on macOS only loads a tree-sitter parser signed by the
   same team, so `make test` fails a macOS tarball unless every Mach-O file is
   signed by that team and `tree-sitter.so` loads into a process signed like
   Rune.app (`scripts/macos-signing.sh`, shared by every language repo).
   Packages are not notarized: Rune installs them without the quarantine
   attribute, so Gatekeeper never assesses them.
2. **Prepare the release.** Fetch tags and submodules
   (`git fetch --tags && git submodule update --init --recursive`), then check
   out a clean, tagged release commit. The `dist-*` targets reject untagged,
   dirty, or non-semver releases. Authenticate `bluectl` via gcloud
   Application Default Credentials and set `BLUE_PGP_KEY` and
   `BLUE_PGP_KEYRING` (see `bluectl release upload -h`).
3. **Publish** every platform for an environment from macOS:

   ```sh
   make dist-staging-all
   make dist-prod-all
   ```

   To publish a single platform, use `dist-<env>-<os>-<arch>`, for example
   `make dist-staging-linux-arm64`. Each platform target checks the tag,
   builds, signs macOS packages, runs `make test`, and uploads `go.tar.gz` via
   `dist.sh`. It selects the pinned project and per-platform release bucket
   from `deploy/bluectl/`; do not run `dist.sh` directly. Platforms that
   already have the version are skipped. On Linux, only the
   `dist-<env>-linux-<arch>` targets run.
