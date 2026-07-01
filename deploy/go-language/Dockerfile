# syntax=docker/dockerfile:1

# Go language extension bundle: Linux cross-compile via Docker.
#
# Reproduces the entire pkg/ layout that the native $(LIB) target builds (a
# bundled target-arch Go toolchain, the tree-sitter parser, query files,
# config.yaml, and the gopls/goimports/dlv/extension_go binaries) so the
# resulting go.tar.gz is identical in structure to a native build.
#
# We cross-compile through the Go toolchain on $BUILDPLATFORM (not under qemu):
# the build-host toolchain runs `go build` while GOOS/GOARCH + a GNU cross
# compiler target the requested architecture.
ARG BUILDPLATFORM
ARG TARGETOS
ARG TARGETARCH

FROM --platform=$BUILDPLATFORM debian:bookworm AS build
ARG TARGETOS
ARG TARGETARCH
ARG GOVERSION
ARG GIT_SSH_KEY
ARG RELEASE_TAR=go.tar.gz

ENV GOPRIVATE=github.com/unstablebuild,unstable.build/* \
	CGO_ENABLED=1 \
	DEBIAN_FRONTEND=noninteractive

# Base tools + the target-arch GNU cross toolchain used to compile the
# tree-sitter parser and cgo objects.
RUN set -eux; \
	[ "$TARGETOS" = linux ] || { echo "unsupported OS $TARGETOS (expected linux)"; exit 1; }; \
	case "$TARGETARCH" in \
		amd64) CROSS=crossbuild-essential-amd64; TRIPLET=x86_64-linux-gnu ;; \
		arm64) CROSS=crossbuild-essential-arm64; TRIPLET=aarch64-linux-gnu ;; \
		*) echo "unsupported arch $TARGETARCH"; exit 1 ;; \
	esac; \
	echo "$TRIPLET" > /tmp/triplet; \
	apt-get update; \
	apt-get install -y --no-install-recommends \
		ca-certificates git openssh-client wget make gcc pkg-config file "$CROSS"; \
	rm -rf /var/lib/apt/lists/*

# Build-host Go toolchain (runs the compiler) -> /opt/go.
# Target-arch Go toolchain (bundled into pkg/) -> /opt/go-target.
RUN set -eux; \
	BUILDARCH="$(dpkg --print-architecture)"; \
	wget -qO /tmp/go-build.tgz "https://go.dev/dl/go${GOVERSION}.linux-${BUILDARCH}.tar.gz"; \
	mkdir -p /opt/go; tar -xzf /tmp/go-build.tgz -C /opt/go --strip-components=1; \
	wget -qO /tmp/go-target.tgz "https://go.dev/dl/go${GOVERSION}.linux-${TARGETARCH}.tar.gz"; \
	mkdir -p /opt/go-target; tar -xzf /tmp/go-target.tgz -C /opt/go-target --strip-components=1; \
	rm -f /tmp/go-build.tgz /tmp/go-target.tgz
ENV PATH=/opt/go/bin:$PATH GOROOT=/opt/go

# SSH / private module access for the unstablebuild Go modules.
RUN git config --global url.ssh://git@github.com/.insteadOf https://github.com/
RUN mkdir -p ~/.ssh && chmod 700 ~/.ssh && \
	printf '%s\n' "$GIT_SSH_KEY" | tr -d '\r' > ~/.ssh/id_rsa && chmod 600 ~/.ssh/id_rsa
# Tolerate transient DNS/network failures populating known_hosts.
RUN ssh-keyscan -t rsa github.com git.unstable.build >> ~/.ssh/known_hosts || true

WORKDIR /src
COPY . .

# Assemble pkg/ exactly like the native $(LIB) recipe.
RUN --mount=type=cache,target=/root/.cache/go-build \
	--mount=type=cache,target=/root/go/pkg/mod \
	set -eux; \
	TRIPLET="$(cat /tmp/triplet)"; CC="${TRIPLET}-gcc"; export CC; \
	cp -R /opt/go-target /out-pkg; \
	mkdir -p /out-pkg/bin /out-pkg/lib; \
	(cd tree-sitter-go && "$CC" -o parser.so -I./src src/*.c -Os -shared -fPIC); \
	cp tree-sitter-go/parser.so /out-pkg/lib/tree-sitter.so; \
	cp tree-sitter-go/queries/tags.scm tree-sitter-go/queries/highlights.scm /out-pkg/lib; \
	cp nvim-treesitter/queries/go/indents.scm /out-pkg/lib; \
	cp nvim-treesitter/queries/go/locals.scm /out-pkg/lib; \
	cp src/folds.scm /out-pkg/lib; \
	cp config.yaml /out-pkg; \
	(cd tools/gopls && GOOS=$TARGETOS GOARCH=$TARGETARCH GOROOT=/opt/go go build -o /out-pkg/bin/gopls .); \
	(cd tools       && GOOS=$TARGETOS GOARCH=$TARGETARCH GOROOT=/opt/go go build -o /out-pkg/bin/goimports ./cmd/goimports); \
	(cd delve       && GOOS=$TARGETOS GOARCH=$TARGETARCH GOROOT=/opt/go go build -o /out-pkg/bin/dlv ./cmd/dlv); \
	(cd rune        && GOOS=$TARGETOS GOARCH=$TARGETARCH GOROOT=/opt/go go build -o /out-pkg/bin/extension_go ./cmd/extension_go); \
	file /out-pkg/bin/extension_go

# Tarball exactly like the native $(TAR) recipe, exported to /out/$RELEASE_TAR.
RUN set -eux; \
	: "${RELEASE_TAR:?RELEASE_TAR build arg is required}"; \
	mkdir -p /out; \
	(cd /out-pkg && tar --no-xattrs --no-acls -czf "/out/$RELEASE_TAR" .); \
	tar -tzf "/out/$RELEASE_TAR" >/dev/null

FROM scratch AS artifact
COPY --from=build /out/ /