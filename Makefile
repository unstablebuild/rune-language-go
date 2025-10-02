SRC=go tools tree-sitter-go
LIB=$(wildcard pkg/**/*) $(wildcard pkg/*) pkg
TAR=go.tar.gz

.PHONY: dist clean
default: $(TAR)

$(LIB): $(SRC)
	@mkdir -p pkg/bin
	cd tree-sitter-go && PREFIX=../pkg LDFLAGS="-arch arm64 -arch x86_64" make install
	mv $(PWD)/pkg/lib/libtree-sitter-go.dylib $(PWD)/pkg/lib/tree-sitter.dylib
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
