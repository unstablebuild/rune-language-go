SRC=go tools tree-sitter-go rune
LIB=$(wildcard pkg/**/*) $(wildcard pkg/*) pkg
TAR=go.tar.gz
NOTARIZE_ZIP=go-notarize.zip
GOVERSION=1.26.5
CODESIGN_IDENTITY=Developer ID Application: Unstable Build, LLC. (YYZRWD888J)
NOTARY_PROFILE=notary-profile
UNAME=$(shell uname)

# GNU tar is named "gtar" on macOS (Homebrew) but is the default "tar" on Linux.
ifeq ($(UNAME),Darwin)
GTAR=gtar
else
GTAR=tar
endif

HOST_OS=$(shell uname | tr '[:upper:]' '[:lower:]')
HOST_ARCH=$(shell uname -m | sed -e 's/^x86_64$$/amd64/' -e 's/^aarch64$$/arm64/')
# Releases are always built on a machine running the target OS (Linux releases
# on Linux, macOS releases on macOS); only the architecture may be cross
# compiled. TARGET_OS defaults to the host OS but may be set explicitly so a
# mismatched cross-OS build (e.g. TARGET_OS=linux on a darwin host) is rejected
# by check-host-os instead of silently bundling the wrong toolchain.
TARGET_OS?=$(HOST_OS)
TARGET_ARCH?=$(HOST_ARCH)

# Cross is non-empty when building for a different arch than the host.
CROSS=$(filter-out $(HOST_ARCH),$(TARGET_ARCH))

# Native builds keep cgo on to match the production release binaries. Cross-arch
# builds disable cgo so the Go binaries link without a target C toolchain.
CGO_ENABLED=$(if $(CROSS),0,1)

# C compiler for the tree-sitter parser. On Linux a cross-arch build needs the
# matching GNU cross toolchain (gcc-*-cross packages); native builds use gcc.
# macOS builds a universal binary in one pass, so CC is unused there.
GNU_TRIPLE_amd64=x86_64-linux-gnu
GNU_TRIPLE_arm64=aarch64-linux-gnu
CC=$(if $(CROSS),$(GNU_TRIPLE_$(TARGET_ARCH))-gcc,gcc)

# extension_go imports ide/syntax and go-tree-sitter, so it must be built with
# CGO enabled even for cross-arch releases (CGO_ENABLED=0 leaves tree-sitter
# Parser/Tree/Query/Language symbols undefined). On macOS, clang cross-compiles
# natively via -arch, so a same-OS cross-arch build only needs the target clang
# arch flag. On Linux, use the matching GNU cross toolchain.
CLANG_ARCH_amd64=x86_64
CLANG_ARCH_arm64=arm64
ifeq ($(HOST_OS),darwin)
EXT_CGO_ENABLED=1
EXT_CC=clang $(if $(CROSS),-arch $(CLANG_ARCH_$(TARGET_ARCH)),)
else
EXT_CGO_ENABLED=1
EXT_CC=$(CC)
endif

BLUECTL_CONFIG_ROOT := $(abspath deploy/bluectl)

# Docker cross-compile: builds the full pkg/ bundle inside Docker for a target
# arch, so no host GNU cross toolchain is required. Linux only.
DOCKER_CROSS_DOCKERFILE := deploy/go-language/Dockerfile
CROSS_OUTPUT_DIR := $(abspath target)

# The bundled Go toolchain is OS-specific and cannot be cross-compiled across
# operating systems: only the architecture may be cross compiled. Building a
# Linux package on macOS (or vice versa) silently bundles the host OS toolchain,
# which then fails on the target with a "go tool version" mismatch. Guard every
# package build, not just the dist-* targets.
.PHONY: check-host-os
check-host-os:
	@if [ "$(TARGET_OS)" != "$(HOST_OS)" ]; then \
	  echo "error: cannot build a '$(TARGET_OS)' package on a '$(HOST_OS)' host; the Go toolchain is OS-specific. Build $(TARGET_OS) releases on a $(TARGET_OS) machine." >&2; \
	  exit 1; \
	fi

# check-release-tag aborts before any build runs when HEAD does not carry a
# publishable release tag (clean, canonical semver, actually tagged). Shared by
# every dist-* target so a "-dirty" or untagged build can never be uploaded.
.PHONY: check-release-tag
check-release-tag:
	@./check-release-tag.sh

DIST_TARGETS := \
	dist-prod-darwin-arm64 dist-prod-darwin-amd64 \
	dist-prod-linux-arm64  dist-prod-linux-amd64  \
	dist-staging-darwin-arm64 dist-staging-darwin-amd64 \
	dist-staging-linux-arm64  dist-staging-linux-amd64

# Docker cross-compile dist targets (Linux only): build the bundle inside
# Docker for a possibly-different arch, then upload via dist.sh.
CROSS_DIST_TARGETS := \
	dist-prod-linux-arm64-cross  dist-prod-linux-amd64-cross \
	dist-staging-linux-arm64-cross dist-staging-linux-amd64-cross

.PHONY: $(DIST_TARGETS) $(CROSS_DIST_TARGETS) linux-cross-compile clean sign notarize notary-credentials
default: $(TAR)

# Build toolchain (host os/arch): runs the compiler. Cross-arch builds set
# GOARCH on top of this.
go:
	wget -O go-build.tar.gz https://go.dev/dl/go$(GOVERSION).$(HOST_OS)-$(HOST_ARCH).tar.gz
	tar -xzf go-build.tar.gz
	rm -f go-build.tar.gz

# Target toolchain (target arch): bundled into the release unmodified. Only
# downloaded when cross-arch building; for native builds we bundle go/ directly.
go-target: | go check-host-os
ifeq ($(CROSS),)
	cp -R go/ go-target
else
	wget -O go-target.tar.gz https://go.dev/dl/go$(GOVERSION).$(TARGET_OS)-$(TARGET_ARCH).tar.gz
	mkdir -p go-target
	tar -xzf go-target.tar.gz -C go-target --strip-components=1
	rm -f go-target.tar.gz
endif

$(LIB): $(SRC) go-target | check-host-os
	cp -R go-target/ pkg
	@mkdir -p pkg/bin pkg/lib
ifeq ($(HOST_OS),darwin)
	cd tree-sitter-go && cc -o parser.so -I./src src/*.c -Os -bundle -arch arm64 -arch x86_64
else
	cd tree-sitter-go && $(CC) -o parser.so -I./src src/*.c -Os -shared -fPIC
endif
	cp tree-sitter-go/parser.so pkg/lib/tree-sitter.so
	cp tree-sitter-go/queries/tags.scm tree-sitter-go/queries/highlights.scm pkg/lib
	cp nvim-treesitter/queries/go/indents.scm pkg/lib
	cp nvim-treesitter/queries/go/locals.scm pkg/lib
	cp src/folds.scm pkg/lib
	cd tools/gopls && CGO_ENABLED=$(CGO_ENABLED) GOOS=$(TARGET_OS) GOARCH=$(TARGET_ARCH) GOROOT=$(PWD)/go $(PWD)/go/bin/go build -o $(PWD)/pkg/bin/gopls .
	cd tools && CGO_ENABLED=$(CGO_ENABLED) GOOS=$(TARGET_OS) GOARCH=$(TARGET_ARCH) GOROOT=../go ../go/bin/go build -o $(PWD)/pkg/bin/goimports ./cmd/goimports
	cp config.yaml pkg
	cd delve && CGO_ENABLED=$(CGO_ENABLED) GOOS=$(TARGET_OS) GOARCH=$(TARGET_ARCH) GOROOT=$(PWD)/go $(PWD)/go/bin/go build -o $(PWD)/pkg/bin/dlv ./cmd/dlv
	cd rune && CGO_ENABLED=$(EXT_CGO_ENABLED) CC="$(EXT_CC)" GOOS=$(TARGET_OS) GOARCH=$(TARGET_ARCH) GOROOT=$(PWD)/go $(PWD)/go/bin/go build -o $(PWD)/pkg/bin/extension_go ./cmd/extension_go

ifeq ($(UNAME),Darwin)
sign: $(LIB)
	codesign --force --options runtime --sign "$(CODESIGN_IDENTITY)" pkg/bin/go
	codesign --force --options runtime --sign "$(CODESIGN_IDENTITY)" pkg/bin/gopls
	codesign --force --options runtime --sign "$(CODESIGN_IDENTITY)" pkg/bin/goimports
	codesign --force --options runtime --sign "$(CODESIGN_IDENTITY)" pkg/bin/dlv
	codesign --force --options runtime --sign "$(CODESIGN_IDENTITY)" pkg/bin/extension_go
	codesign --force --options runtime --sign "$(CODESIGN_IDENTITY)" pkg/lib/tree-sitter.so

$(NOTARIZE_ZIP): sign
	zip $(NOTARIZE_ZIP) pkg/bin/go pkg/bin/gopls pkg/bin/goimports pkg/bin/dlv pkg/bin/extension_go pkg/lib/tree-sitter.so

notarize: $(NOTARIZE_ZIP)
	xcrun notarytool submit $(NOTARIZE_ZIP) --keychain-profile "$(NOTARY_PROFILE)" --wait
else
sign: $(LIB)
	@echo "Skipping codesign (not on macOS)"

notarize: sign
	@echo "Skipping notarization (not on macOS)"
endif

$(TAR): $(LIB) sign
	cd pkg && $(GTAR) --no-xattrs --no-acls -czvf ../$(TAR) .

# dist-<env>-<os>-<arch>: build (cross compiling the architecture when it
# differs from the host), sign/notarize, and upload to the bluectl project-id
# pinned by deploy/bluectl/<env>/<os>-<arch>/config. Pattern stem is
# <env>-<os>-<arch>, e.g. "prod-darwin-arm64".
#
# The target OS must match the host OS: Linux releases are built on Linux and
# macOS releases on macOS. Only the architecture may be cross compiled. The
# build is driven through a recursive make so TARGET_ARCH is set before the
# $(TAR) prerequisite chain is evaluated.
# check-release-tag is listed first so the tag is validated before any build,
# sign, or notarize work runs.
$(DIST_TARGETS): dist-%: check-release-tag
	@env=$$(echo $* | cut -d- -f1); \
	 os=$$(echo $*  | cut -d- -f2); \
	 arch=$$(echo $* | cut -d- -f3); \
	 if [ "$$os" != "$(HOST_OS)" ]; then \
	   echo "error: $@ targets OS '$$os' but host OS is '$(HOST_OS)'; build $$os releases on a $$os machine" >&2; \
	   exit 1; \
	 fi; \
	 $(MAKE) clean; \
	 $(MAKE) notarize $(TAR) TARGET_OS=$$os TARGET_ARCH=$$arch; \
	 BLUECTL_CONFIG_DIR=$(BLUECTL_CONFIG_ROOT)/$$env/$$os-$$arch \
	 BLUE_TARGET_OS=$$os BLUE_TARGET_ARCH=$$arch ./dist.sh

# linux-cross-compile builds the full pkg/ bundle inside Docker for TARGET_ARCH,
# dropping go.tar.gz into $(CROSS_OUTPUT_DIR). No host GNU cross toolchain is
# required. GIT_SSH_KEY must be exported for private Go module access.
linux-cross-compile:
	@rm -rf $(CROSS_OUTPUT_DIR)
	@mkdir -p $(CROSS_OUTPUT_DIR)
	docker buildx build --rm \
		-f $(DOCKER_CROSS_DOCKERFILE) \
		--platform linux/$(TARGET_ARCH) \
		--build-arg GOVERSION=$(GOVERSION) \
		--build-arg GIT_SSH_KEY="$$GIT_SSH_KEY" \
		--build-arg RELEASE_TAR=$(TAR) \
		--output type=local,dest=$(CROSS_OUTPUT_DIR) \
		.

# dist-<env>-linux-<arch>-cross mirror the native dist-<env>-linux-<arch>
# targets but build the bundle through the Docker cross-compile path instead of
# the host toolchain. Linux only; darwin cannot be built in Linux Docker.
# check-release-tag is listed first so the tag is validated before any Docker
# cross-compile work runs.
$(CROSS_DIST_TARGETS): dist-%-cross: check-release-tag
	@env=$$(echo $*  | cut -d- -f1); \
	 os=$$(echo $*   | cut -d- -f2); \
	 arch=$$(echo $* | cut -d- -f3); \
	 if [ "$$os" != "linux" ]; then \
	   echo "error: $@ is Linux-only (docker cross); use dist-$$env-$$os-$$arch for $$os" >&2; \
	   exit 1; \
	 fi; \
	 $(MAKE) clean; \
	 $(MAKE) linux-cross-compile TARGET_OS=linux TARGET_ARCH=$$arch; \
	 BLUECTL_CONFIG_DIR=$(BLUECTL_CONFIG_ROOT)/$$env/$$os-$$arch \
	 BLUE_TARGET_OS=linux BLUE_TARGET_ARCH=$$arch \
	 BLUE_RELEASE_TAR=$(CROSS_OUTPUT_DIR)/$(TAR) ./dist.sh

notary-credentials:
	xcrun notarytool store-credentials "$(NOTARY_PROFILE)" --team-id "YYZRWD888J"

clean:
	rm -rf go
	rm -rf go-target
	rm -rf $(TAR)
	rm -rf $(NOTARIZE_ZIP)
	rm -rf $(CROSS_OUTPUT_DIR)
	rm -rf pkg/
	rm -rf go/bin/
