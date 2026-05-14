SRC=go tools tree-sitter-go rune
LIB=$(wildcard pkg/**/*) $(wildcard pkg/*) pkg
TAR=go.tar.gz
NOTARIZE_ZIP=go-notarize.zip
CC=gcc
GTAR=gtar
GOVERSION=1.26.2
CODESIGN_IDENTITY=Developer ID Application: Unstable Build, LLC. (YYZRWD888J)
NOTARY_PROFILE=notary-profile
UNAME=$(shell uname)

BLUECTL_CONFIG_ROOT := $(abspath deploy/bluectl)

DIST_TARGETS := \
	dist-prod-darwin-arm64 dist-prod-darwin-amd64 \
	dist-prod-linux-arm64  dist-prod-linux-amd64  \
	dist-staging-darwin-arm64 dist-staging-darwin-amd64 \
	dist-staging-linux-arm64  dist-staging-linux-amd64

.PHONY: $(DIST_TARGETS) clean sign notarize notary-credentials
default: $(TAR)

go:
	wget -O go-src.tar.gz https://go.dev/dl/go$(GOVERSION).darwin-arm64.tar.gz
	tar -xzvf go-src.tar.gz

$(LIB): $(SRC)
	cp -R go/ pkg
	@mkdir -p pkg/bin pkg/lib
	cd tree-sitter-go && $(CC) -o parser.so -I./src src/*.c -Os -bundle -arch arm64 -arch x86_64
	cp tree-sitter-go/parser.so pkg/lib/tree-sitter.so
	cp tree-sitter-go/queries/tags.scm tree-sitter-go/queries/highlights.scm pkg/lib
	cp nvim-treesitter/queries/go/indents.scm pkg/lib
	cp nvim-treesitter/queries/go/locals.scm pkg/lib
	cp src/folds.scm pkg/lib
	cd tools/gopls && GOBIN=$(PWD)/pkg/bin GOROOT=$(PWD)/go $(PWD)/pkg/bin/go install .
	cd tools && GOBIN=$(PWD)/pkg/bin GOROOT=../go ../go/bin/go install ./cmd/goimports
	cp config.yaml pkg
	cd delve && GOBIN=$(PWD)/pkg/bin GOROOT=$(PWD)/go $(PWD)/go/bin/go install ./cmd/dlv
	cd rune && GOBIN=$(PWD)/pkg/bin GOROOT=$(PWD)/go $(PWD)/go/bin/go install ./cmd/extension_go

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

# dist-<env>-<os>-<arch>: build, sign/notarize, and upload to the
# bluectl project-id pinned by deploy/bluectl/<env>/<os>-<arch>/config.
# Pattern stem is <env>-<os>-<arch>, e.g. "prod-darwin-arm64".
$(DIST_TARGETS): dist-%: clean notarize $(TAR)
	@env=$$(echo $* | cut -d- -f1); \
	 os=$$(echo $*  | cut -d- -f2); \
	 arch=$$(echo $* | cut -d- -f3); \
	 BLUECTL_CONFIG_DIR=$(BLUECTL_CONFIG_ROOT)/$$env/$$os-$$arch \
	 BLUE_TARGET_OS=$$os BLUE_TARGET_ARCH=$$arch ./dist.sh

notary-credentials:
	xcrun notarytool store-credentials "$(NOTARY_PROFILE)" --team-id "YYZRWD888J"

clean:
	rm -rf go
	rm -rf $(TAR)
	rm -rf $(NOTARIZE_ZIP)
	rm -rf pkg/
	rm -rf go/bin/
