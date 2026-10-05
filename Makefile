TAR=go.tar.gz
GOVERSION=1.27.1

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
DIST_ALL_TARGETS=$(foreach env,$(ENVS),dist-$(env)-all)

# Fields of a dist target stem "<env>-<os>-<arch>".
dist_env=$(word 1,$(subst -, ,$(1)))
dist_os=$(word 2,$(subst -, ,$(1)))
dist_arch=$(word 3,$(subst -, ,$(1)))
dist_config=$(BLUECTL_CONFIG_ROOT)/$(call dist_env,$(1))/$(call dist_os,$(1))-$(call dist_arch,$(1))

# Release version, the tag check-release-tag validates.
VERSION=$(shell git describe --tags --dirty)

.PHONY: default pkg check-release-tag clean $(DIST_TARGETS) $(DIST_ALL_TARGETS)
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

$(TAR): pkg
	cd pkg && $(GTAR) --no-xattrs --no-acls -czvf ../$(TAR) .

# check-release-tag aborts before any build runs when HEAD does not carry a
# publishable release tag (clean, canonical semver, actually tagged).
check-release-tag:
	@./check-release-tag.sh

# dist-<env>-<os>-<arch> builds the package and uploads it with the bluectl
# config pinned in deploy/bluectl/<env>/<os>-<arch>. It skips platforms that
# already have this version, so an interrupted dist-<env>-all can be rerun.
# darwin packages must be built on macOS (clang compiles the parser); linux
# packages build on any host.
$(DIST_TARGETS): dist-%: check-release-tag
	@if bluectl -c $(call dist_config,$*) release describe go $(VERSION) >/dev/null 2>&1; then \
	  echo "go $(VERSION) is already released for $*; skipping"; \
	else \
	  $(MAKE) $(TAR) TARGET_OS=$(call dist_os,$*) TARGET_ARCH=$(call dist_arch,$*) && \
	  BLUECTL_CONFIG_DIR=$(call dist_config,$*) \
	  BLUE_TARGET_OS=$(call dist_os,$*) BLUE_TARGET_ARCH=$(call dist_arch,$*) ./dist.sh; \
	fi

# dist-<env>-all publishes every platform for <env>, one after another.
$(DIST_ALL_TARGETS): dist-%-all: check-release-tag
	for platform in $(PLATFORMS); do $(MAKE) dist-$*-$$platform || exit 1; done

clean:
	rm -rf go pkg $(TAR)