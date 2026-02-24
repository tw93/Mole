# Makefile for Mole

.PHONY: all build clean release

# Output directory
BIN_DIR := bin

# Binaries
ANALYZE := analyze
STATUS := status
MENUBAR := menubar

# Source directories
ANALYZE_SRC := ./cmd/analyze
STATUS_SRC := ./cmd/status
MENUBAR_SRC := ./cmd/menubar

# Build flags
LDFLAGS := -s -w

all: build

# Local build (current architecture)
build:
	@echo "Building for local architecture..."
	go build -ldflags="$(LDFLAGS)" -o $(BIN_DIR)/$(ANALYZE)-go $(ANALYZE_SRC)
	go build -ldflags="$(LDFLAGS)" -o $(BIN_DIR)/$(STATUS)-go $(STATUS_SRC)
	go build -ldflags="$(LDFLAGS)" -o $(BIN_DIR)/$(MENUBAR)-go $(MENUBAR_SRC)

# Release build targets (run on native architectures for CGO support)
release-amd64:
	@echo "Building release binaries (amd64)..."
	GOOS=darwin GOARCH=amd64 go build -ldflags="$(LDFLAGS)" -o $(BIN_DIR)/$(ANALYZE)-darwin-amd64 $(ANALYZE_SRC)
	GOOS=darwin GOARCH=amd64 go build -ldflags="$(LDFLAGS)" -o $(BIN_DIR)/$(STATUS)-darwin-amd64 $(STATUS_SRC)
	GOOS=darwin GOARCH=amd64 go build -ldflags="$(LDFLAGS)" -o $(BIN_DIR)/$(MENUBAR)-darwin-amd64 $(MENUBAR_SRC)

release-arm64:
	@echo "Building release binaries (arm64)..."
	GOOS=darwin GOARCH=arm64 go build -ldflags="$(LDFLAGS)" -o $(BIN_DIR)/$(ANALYZE)-darwin-arm64 $(ANALYZE_SRC)
	GOOS=darwin GOARCH=arm64 go build -ldflags="$(LDFLAGS)" -o $(BIN_DIR)/$(STATUS)-darwin-arm64 $(STATUS_SRC)
	GOOS=darwin GOARCH=arm64 go build -ldflags="$(LDFLAGS)" -o $(BIN_DIR)/$(MENUBAR)-darwin-arm64 $(MENUBAR_SRC)

clean:
	@echo "Cleaning binaries..."
	rm -f $(BIN_DIR)/$(ANALYZE)-* $(BIN_DIR)/$(STATUS)-* $(BIN_DIR)/$(MENUBAR)-* $(BIN_DIR)/$(ANALYZE)-go $(BIN_DIR)/$(STATUS)-go $(BIN_DIR)/$(MENUBAR)-go
