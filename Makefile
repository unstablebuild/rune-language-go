TAR=go.tar.gz
GOVERSION=1.27.1

# Rune's macOS app runs with the hardened runtime and only loads libraries
# signed by its own team: an ad-hoc signed tree-sitter.so fails to load. darwin
# packages sign every Mach-O file with the Developer ID
# (scripts/macos-signing.sh), and scripts/test.sh checks the tarball. Packages
# are not notarized: Rune installs them without the quarantine attribute, so
# Gatekeeper never assesses them.
TEAM_ID=YYZRWD888J
CODESIGN_IDENTITY=Developer ID Application: Unstable Build, LLC. ($(TEAM_ID))
MACOS_SIGNING=TEAM_ID=$(TEAM_ID) CODESIGN_IDENTITY="$(CODESIGN_IDENTITY)" \
	TARGET_ARCH=$(TARGET_ARCH) ./scripts/macos-signing.sh

HOST_OS=$(shell uname | tr '[:upper:]' '[:lower:]')
HOST_ARCH=$(shell uname -m | sed -e 's/^x86_64$$/amd64/' -e 's/^aarch64$$/arm64/')
TARGET_OS?=$(HOST_OS)
TARGET_ARCH?=$(HOST_ARCH)

# GNU tar is named "gtar" on macOS (Homebrew) but is the default "tar" on Linux.
ifeq ($(HOST_OS),darwin)
GTAR=gtar
else
GTAR=tar
endif

# Go distributions from go.dev, downloaded into go/: the host one runs the
# builds and the target one is bundled into the package unmodified.
GO_HOST=go/go$(GOVERSION).$(HOST_OS)-$(HOST_ARCH)
GO_TARGET_TGZ=go/go$(GOVERSION).$(TARGET_OS)-$(TARGET_ARCH).tar.gz

# gopls, goimports, dlv and extension_go are pure Go, so the host toolchain
# cross-compiles them for every target.
GO=CGO_ENABLED=0 GOOS=$(TARGET_OS) GOARCH=$(TARGET_ARCH) GOROOT=$(CURDIR)/$(GO_HOST) $(CURDIR)/$(GO_HOST)/bin/go

# The tree-sitter parser is C. Pin it to Rune's platform floors: macOS 13.3 and
# glibc 2.28. zig cc cross-compiles it for Linux from any host.
MACOS_MIN=13.3
GLIBC_MIN=2.28
ZIG_ARCH_amd64=x86_64
ZIG_ARCH_arm64=aarch64

BLUECTL_CONFIG_ROOT=$(abspath deploy/bluectl)
ENVS=prod staging
PLATFORMS=darwin-arm64 darwin-amd64 linux-arm64 linux-amd64
DIST_TARGETS=$(foreach env,$(ENVS),$(addprefix dist-$(env)-,$(PLATFORMS)))
DARWIN_DIST_TARGETS=$(filter %-darwin-arm64 %-darwin-amd64,$(DIST_TARGETS))
DIST_ALL_TARGETS=$(foreach env,$(ENVS),dist-$(env)-all)

# Fields of a dist target stem "<env>-<os>-<arch>".
dist_env=$(word 1,$(subst -, ,$(1)))
dist_os=$(word 2,$(subst -, ,$(1)))
dist_arch=$(word 3,$(subst -, ,$(1)))
dist_config=$(BLUECTL_CONFIG_ROOT)/$(call dist_env,$(1))/$(call dist_os,$(1))-$(call dist_arch,$(1))

# Release version, the tag check-release-tag validates.
VERSION=$(shell git describe --tags --dirty)

.PHONY: default pkg sign test check-macos check-release-tag clean $(DIST_TARGETS) $(DIST_ALL_TARGETS)
default: $(TAR)

go/%.tar.gz:
	@mkdir -p go
	wget -O $@.tmp https://go.dev/dl/$*.tar.gz
	mv $@.tmp $@

$(GO_HOST): | $(GO_HOST).tar.gz
	rm -rf $@.tmp
	mkdir -p $@.tmp
	tar -xzf $(GO_HOST).tar.gz -C $@.tmp --strip-components=1
	mv $@.tmp $@

# pkg/ is rebuilt from scratch every time, so it never mixes platforms.
pkg: | $(GO_HOST) $(GO_TARGET_TGZ)
	rm -rf pkg
	mkdir -p pkg
	tar -xzf $(GO_TARGET_TGZ) -C pkg --strip-components=1
	mkdir -p pkg/bin pkg/lib
ifeq ($(TARGET_OS),darwin)
	clang -o pkg/lib/tree-sitter.so -Itree-sitter-go/src tree-sitter-go/src/*.c -Os -bundle -arch arm64 -arch x86_64 -mmacosx-version-min=$(MACOS_MIN)
else
	zig cc -target $(ZIG_ARCH_$(TARGET_ARCH))-linux-gnu.$(GLIBC_MIN) -o pkg/lib/tree-sitter.so -Itree-sitter-go/src tree-sitter-go/src/*.c -Os -shared -fPIC
endif
	cp tree-sitter-go/queries/tags.scm tree-sitter-go/queries/highlights.scm pkg/lib
	cp nvim-treesitter/queries/go/indents.scm nvim-treesitter/queries/go/locals.scm pkg/lib
	cp src/folds.scm pkg/lib
	cp config.yaml pkg
	$(GO) build -C tools/gopls -o $(CURDIR)/pkg/bin/gopls .
	$(GO) build -C tools -o $(CURDIR)/pkg/bin/goimports ./cmd/goimports
	$(GO) build -C delve -o $(CURDIR)/pkg/bin/dlv ./cmd/dlv
	$(GO) build -C rune -o $(CURDIR)/pkg/bin/extension_go ./cmd/extension_go

ifeq ($(TARGET_OS),darwin)
# Every Mach-O file in pkg/, found by scanning, so a new binary is signed too.
# That includes the Go distribution's own bin/ and pkg/tool/ binaries.
sign: pkg
	$(MACOS_SIGNING) sign pkg

$(TAR): sign
endif

$(TAR): pkg
	cd pkg && $(GTAR) --no-xattrs --no-acls -czvf ../$(TAR) .

# Checks the tarball itself, independently of how it was built: for darwin,
# that Rune.app can load it (scripts/test.sh).
test: $(TAR)
	TAR=$(TAR) TARGET_OS=$(TARGET_OS) TARGET_ARCH=$(TARGET_ARCH) \
		TEAM_ID=$(TEAM_ID) CODESIGN_IDENTITY="$(CODESIGN_IDENTITY)" ./scripts/test.sh

# darwin packages are signed, which needs macOS and the Developer ID identity;
# fail before any build work without them.
check-macos:
	@$(MACOS_SIGNING) preflight

# check-release-tag aborts before any build runs when HEAD does not carry a
# publishable release tag (clean, canonical semver, actually tagged).
check-release-tag:
	@./check-release-tag.sh

# dist-<env>-<os>-<arch> builds the package and uploads it with the bluectl
# config pinned in deploy/bluectl/<env>/<os>-<arch>. It skips platforms that
# already have this version, so an interrupted dist-<env>-all can be rerun.
# It uploads the tarball that `make test` just checked. darwin packages need
# macOS; linux packages build on any host.
$(DARWIN_DIST_TARGETS) $(DIST_ALL_TARGETS): check-macos
$(DIST_TARGETS) $(DIST_ALL_TARGETS): check-release-tag
$(DIST_TARGETS): dist-%:
	@if bluectl -c $(call dist_config,$*) release describe go $(VERSION) >/dev/null 2>&1; then \
	  echo "go $(VERSION) is already released for $*; skipping"; \
	else \
	  $(MAKE) test TARGET_OS=$(call dist_os,$*) TARGET_ARCH=$(call dist_arch,$*) && \
	  BLUECTL_CONFIG_DIR=$(call dist_config,$*) \
	  BLUE_TARGET_OS=$(call dist_os,$*) BLUE_TARGET_ARCH=$(call dist_arch,$*) ./dist.sh; \
	fi

# dist-<env>-all publishes every platform for <env>, one after another. It
# includes the darwin packages, so it only runs on macOS.
$(DIST_ALL_TARGETS): dist-%-all:
	for platform in $(PLATFORMS); do $(MAKE) dist-$*-$$platform || exit 1; done

clean:
	rm -rf go pkg $(TAR)