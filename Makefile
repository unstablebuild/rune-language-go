SRC=go tools tree-sitter-go rune
LIB=$(wildcard pkg/**/*) $(wildcard pkg/*) pkg
TAR=go.tar.gz
NOTARIZE_ZIP=go-notarize.zip
GTAR=gtar
GOVERSION=1.26.4
CODESIGN_IDENTITY=Developer ID Application: Unstable Build, LLC. (YYZRWD888J)
NOTARY_PROFILE=notary-profile
UNAME=$(shell uname)

# Releases are always built on a machine running the target OS (Linux releases
# on Linux, macOS releases on macOS); only the architecture may be cross
# compiled. TARGET_OS therefore always equals the host OS, while TARGET_ARCH
# may differ to produce the other arch for the same OS.
HOST_OS=$(shell uname | tr '[:upper:]' '[:lower:]')
HOST_ARCH=$(shell uname -m | sed -e 's/^x86_64$$/amd64/' -e 's/^aarch64$$/arm64/')
TARGET_OS=$(HOST_OS)
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

BLUECTL_CONFIG_ROOT := $(abspath deploy/bluectl)

DIST_TARGETS := \
	dist-prod-darwin-arm64 dist-prod-darwin-amd64 \
	dist-prod-linux-arm64  dist-prod-linux-amd64  \
	dist-staging-darwin-arm64 dist-staging-darwin-amd64 \
	dist-staging-linux-arm64  dist-staging-linux-amd64

.PHONY: $(DIST_TARGETS) clean sign notarize notary-credentials
default: $(TAR)

# Build toolchain (host os/arch): runs the compiler. Cross-arch builds set
# GOARCH on top of this.
go:
	wget -O go-build.tar.gz https://go.dev/dl/go$(GOVERSION).$(HOST_OS)-$(HOST_ARCH).tar.gz
	tar -xzf go-build.tar.gz
	rm -f go-build.tar.gz

# Target toolchain (target arch): bundled into the release unmodified. Only
# downloaded when cross-arch building; for native builds we bundle go/ directly.
go-target: | go
ifeq ($(CROSS),)
	cp -R go/ go-target
else
	wget -O go-target.tar.gz https://go.dev/dl/go$(GOVERSION).$(TARGET_OS)-$(TARGET_ARCH).tar.gz
	mkdir -p go-target
	tar -xzf go-target.tar.gz -C go-target --strip-components=1
	rm -f go-target.tar.gz
endif

$(LIB): $(SRC) go-target
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
	cd rune && CGO_ENABLED=$(CGO_ENABLED) GOOS=$(TARGET_OS) GOARCH=$(TARGET_ARCH) GOROOT=$(PWD)/go $(PWD)/go/bin/go build -o $(PWD)/pkg/bin/extension_go ./cmd/extension_go

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
	xcrun notarytool submit $(NOTARIZE_ZIP) --keychain-profile "$(NOTARY_PROFILE)"
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
$(DIST_TARGETS): dist-%:
	@env=$$(echo $* | cut -d- -f1); \
	 os=$$(echo $*  | cut -d- -f2); \
	 arch=$$(echo $* | cut -d- -f3); \
	 if [ "$$os" != "$(HOST_OS)" ]; then \
	   echo "error: $@ targets OS '$$os' but host OS is '$(HOST_OS)'; build $$os releases on a $$os machine" >&2; \
	   exit 1; \
	 fi; \
	 $(MAKE) clean; \
	 $(MAKE) notarize $(TAR) TARGET_ARCH=$$arch; \
	 BLUECTL_CONFIG_DIR=$(BLUECTL_CONFIG_ROOT)/$$env/$$os-$$arch \
	 BLUE_TARGET_OS=$$os BLUE_TARGET_ARCH=$$arch ./dist.sh

notary-credentials:
	xcrun notarytool store-credentials "$(NOTARY_PROFILE)" --team-id "YYZRWD888J"

clean:
	rm -rf go
	rm -rf go-target
	rm -rf $(TAR)
	rm -rf $(NOTARIZE_ZIP)
	rm -rf pkg/
	rm -rf go/bin/
