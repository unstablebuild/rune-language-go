SRC=go tools tree-sitter-go
LIB=$(wildcard pkg/**/*) $(wildcard pkg/*) pkg
TAR=go.tar.gz
NOTARIZE_ZIP=go-notarize.zip
CC=gcc
GOVERSION=1.26.1
CODESIGN_IDENTITY=Developer ID Application: Unstable Build, LLC. (YYZRWD888J)
NOTARY_PROFILE=notary-profile
UNAME=$(shell uname)

.PHONY: dist clean sign notarize notary-credentials
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
	cd blue && GOBIN=$(PWD)/pkg/bin GOROOT=$(PWD)/go $(PWD)/go/bin/go install ./cmd/extension_go

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
	cd pkg && tar -czvf ../$(TAR) .

dist: notarize $(TAR)
	@ ./dist.sh

notary-credentials:
	xcrun notarytool store-credentials "$(NOTARY_PROFILE)" --team-id "YYZRWD888J"

clean:
	rm -rf go
	rm -rf $(TAR)
	rm -rf $(NOTARIZE_ZIP)
	rm -rf pkg/
	rm -rf go/bin/
