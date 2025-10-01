LIBSRC=$(wildcard pkg/**/*) $(wildcard pkg/*)
TAR=go.tar.gz

.PHONY: dist
default: $(TAR)

$(TAR): $(LIBSRC)
	-rm -rf $(TAR)
	cd pkg && tar -czvf ../go.tar.gz .

dist: $(TAR)
	@ ./dist.sh
