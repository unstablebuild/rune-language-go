SRC=go tools tree-sitter-go
LIB=$(wildcard pkg/**/*) $(wildcard pkg/*) pkg
TAR=go.tar.gz
CC=gcc

.PHONY: dist clean
default: $(TAR)

$(LIB): $(SRC)
	@mkdir -p pkg/bin pkg/lib
	cd tree-sitter-go $(CC) -o parser.so -I./src src/*.c -Os -bundle -arch arm64 -arch x86_64
	cp tree-sitter-go/parser.so pkg/lib/tree-sitter.so
	cp tree-sitter-go/queries/tags.scm tree-sitter-go/queries/highlights.scm pkg/lib
	cp nvim-treesitter/queries/go/indents.scm nvim-treesitter/queries/go/folds.scm pkg/lib
	cd go/src && ./make.bash && cp ../bin/** ../../pkg/bin
	cd tools/gopls && GOBIN=$(PWD)/pkg/bin GOROOT=../../go ../../go/bin/go install .
	cd tools && GOBIN=$(PWD)/pkg/bin GOROOT=../go ../go/bin/go install ./cmd/goimports

$(TAR): $(LIB)
	cd pkg && tar -czvf ../go.tar.gz .

dist: $(TAR)
	@ ./dist.sh

clean:
	rm -rf $(TAR)
	rm -rf $(LIB)
