SRC=$(wildcard tree-sitter-go/**/*) $(wildcard tree-sitter-go/*) $(wildcard tree-sitter-go/**/**/*)
LIB=$(wildcard pkg/**/*) $(wildcard pkg/*) pkg
TAR=go.tar.gz

.PHONY: dist clean
default: $(TAR)

$(LIB): $(SRC)
	cd tree-sitter-go && PREFIX=../pkg LDFLAGS="-arch arm64 -arch x86_64" make install

$(TAR): $(LIB)
	cd pkg && tar -czvf ../go.tar.gz .

dist: $(TAR)
	@ ./dist.sh

clean:
	rm -rf $(TAR)
	rm -rf $(LIB)
