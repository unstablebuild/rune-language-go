SRC=go tools tree-sitter-go
LIB=$(wildcard pkg/**/*) $(wildcard pkg/*) pkg
TAR=go.tar.gz
CC=gcc
GOVERSION=1.26.0

.PHONY: dist clean
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
	cp settings.json pkg
	cd delve && GOBIN=$(PWD)/pkg/bin GOROOT=$(PWD)/go $(PWD)/go/bin/go install ./cmd/dlv
	cd blue && GOBIN=$(PWD)/pkg/bin GOROOT=$(PWD)/go $(PWD)/go/bin/go install ./cmd/extension_go

$(TAR): $(LIB)
	cd pkg && tar -czvf ../go.tar.gz .

dist: $(TAR)
	@ ./dist.sh

clean:
	rm -rf go
	rm -rf $(TAR)
	rm -rf pkg/
	rm -rf go/bin/
