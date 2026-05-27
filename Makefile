# Makefile for Mole

.PHONY: all build clean check format test test-go verify release release-amd64 release-arm64 mod-download

# Output directory
BIN_DIR := bin

# Go toolchain
GO ?= go
GO_DOWNLOAD_RETRIES ?= 3

# Binaries
ANALYZE := analyze
STATUS := status
SPEEDTEST := speedtest

# Source directories
ANALYZE_SRC := ./cmd/analyze
STATUS_SRC := ./cmd/status
SPEEDTEST_SRC := ./cmd/speedtest

# Build flags
LDFLAGS := -s -w

all: build

# Download modules with retries to mitigate transient proxy/network EOF errors.
mod-download:
	@attempt=1; \
	while [ $$attempt -le $(GO_DOWNLOAD_RETRIES) ]; do \
		echo "Downloading Go modules ($$attempt/$(GO_DOWNLOAD_RETRIES))..."; \
		if $(GO) mod download; then \
			exit 0; \
		fi; \
		sleep $$((attempt * 2)); \
		attempt=$$((attempt + 1)); \
	done; \
	echo "Go module download failed after $(GO_DOWNLOAD_RETRIES) attempts"; \
	exit 1

# Local build (current architecture)
build: mod-download
	@echo "Building for local architecture..."
	$(GO) build -ldflags="$(LDFLAGS)" -o $(BIN_DIR)/$(ANALYZE)-go $(ANALYZE_SRC)
	$(GO) build -ldflags="$(LDFLAGS)" -o $(BIN_DIR)/$(STATUS)-go $(STATUS_SRC)
	$(GO) build -ldflags="$(LDFLAGS)" -o $(BIN_DIR)/$(SPEEDTEST)-go $(SPEEDTEST_SRC)

check:
	./scripts/check.sh --no-format

format:
	./scripts/check.sh --format

test:
	MOLE_TEST_NO_AUTH=1 ./scripts/test.sh

test-go:
	$(GO) test ./...

verify: check test-go

# Release build targets (run on native architectures for CGO support)
release-amd64: mod-download
	@echo "Building release binaries (amd64)..."
	GOOS=darwin GOARCH=amd64 $(GO) build -ldflags="$(LDFLAGS)" -o $(BIN_DIR)/$(ANALYZE)-darwin-amd64 $(ANALYZE_SRC)
	GOOS=darwin GOARCH=amd64 $(GO) build -ldflags="$(LDFLAGS)" -o $(BIN_DIR)/$(STATUS)-darwin-amd64 $(STATUS_SRC)
	GOOS=darwin GOARCH=amd64 $(GO) build -ldflags="$(LDFLAGS)" -o $(BIN_DIR)/$(SPEEDTEST)-darwin-amd64 $(SPEEDTEST_SRC)

release-arm64: mod-download
	@echo "Building release binaries (arm64)..."
	GOOS=darwin GOARCH=arm64 $(GO) build -ldflags="$(LDFLAGS)" -o $(BIN_DIR)/$(ANALYZE)-darwin-arm64 $(ANALYZE_SRC)
	GOOS=darwin GOARCH=arm64 $(GO) build -ldflags="$(LDFLAGS)" -o $(BIN_DIR)/$(STATUS)-darwin-arm64 $(STATUS_SRC)
	GOOS=darwin GOARCH=arm64 $(GO) build -ldflags="$(LDFLAGS)" -o $(BIN_DIR)/$(SPEEDTEST)-darwin-arm64 $(SPEEDTEST_SRC)

clean:
	@echo "Cleaning binaries..."
	rm -f $(BIN_DIR)/$(ANALYZE)-* $(BIN_DIR)/$(STATUS)-* $(BIN_DIR)/$(SPEEDTEST)-* \
		$(BIN_DIR)/$(ANALYZE)-go $(BIN_DIR)/$(STATUS)-go $(BIN_DIR)/$(SPEEDTEST)-go
