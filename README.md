# Go language package

To install Go support in Rune, run this command in the Rune console:

```text
pkg install go
```

This package ships the Go toolchain, `gopls`, `goimports`, `dlv`, the Go
extension, and the tree-sitter grammar. The release instructions below are for
Rune maintainers.

## Release runbook

1. **Prepare the build host.** Build macOS (`darwin`) artifacts on macOS and
   Linux artifacts on Linux; only the architecture can be cross-built. The
   Makefile downloads the pinned Go toolchain itself. Install a C compiler,
   `wget`, `bluectl`, and tar (GNU `gtar` on macOS). Linux cross-architecture
   builds need the target GNU compiler (`aarch64-linux-gnu-gcc` or
   `x86_64-linux-gnu-gcc`), or Docker for the `-cross` targets below. macOS
   releases need the configured Developer ID signing identity and a
   notarytool profile (`make notary-credentials` to set it up).
2. **Prepare the release.** Fetch tags and submodules
   (`git fetch --tags && git submodule update --init --recursive`), then check
   out a clean, tagged release commit. The `dist-*` targets reject untagged,
   dirty, or non-semver releases. Authenticate `bluectl` via gcloud
   Application Default Credentials and set `BLUE_PGP_KEY` and
   `BLUE_PGP_KEYRING` (see `bluectl release upload -h`).
3. **Publish** with the target matching the environment, OS, and architecture:

   ```sh
   make dist-staging-darwin-arm64   # on macOS
   make dist-prod-darwin-amd64      # on macOS
   make dist-staging-linux-arm64    # on Linux
   make dist-prod-linux-amd64       # on Linux
   ```

   All `staging`/`prod` × `darwin`/`linux` × `arm64`/`amd64` combinations
   follow this pattern. Each target checks the tag, cleans, builds,
   signs/notarizes on macOS, and uploads `go.tar.gz` via `dist.sh`. It selects
   the pinned project and per-platform release bucket from `deploy/bluectl/`;
   do not run `dist.sh` directly. Run a separate target for each architecture.

   On Linux, append `-cross` (e.g. `make dist-prod-linux-arm64-cross`) to
   build inside Docker instead of with a host cross-compiler.
