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
   the Linux packages, since the macOS tree-sitter parser is compiled with the
   Xcode command line tools. The Makefile downloads the pinned Go toolchains
   itself. Install `wget`, `zig` (it compiles the Linux tree-sitter parser),
   `bluectl`, and tar (GNU `gtar` on macOS).
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
   builds, and uploads `go.tar.gz` via `dist.sh`. It selects the pinned
   project and per-platform release bucket from `deploy/bluectl/`; do not run
   `dist.sh` directly.
