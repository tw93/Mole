# Makefile for Mole

.PHONY: all build clean release menubar-lib menubar-app

# Output directory
BIN_DIR := bin

# Binaries
ANALYZE := analyze
STATUS := status
MENUBAR_LIB := libmolemetrics

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

# Release build targets (run on native architectures for CGO support)
release-amd64:
	@echo "Building release binaries (amd64)..."
	GOOS=darwin GOARCH=amd64 go build -ldflags="$(LDFLAGS)" -o $(BIN_DIR)/$(ANALYZE)-darwin-amd64 $(ANALYZE_SRC)
	GOOS=darwin GOARCH=amd64 go build -ldflags="$(LDFLAGS)" -o $(BIN_DIR)/$(STATUS)-darwin-amd64 $(STATUS_SRC)

release-arm64:
	@echo "Building release binaries (arm64)..."
	GOOS=darwin GOARCH=arm64 go build -ldflags="$(LDFLAGS)" -o $(BIN_DIR)/$(ANALYZE)-darwin-arm64 $(ANALYZE_SRC)
	GOOS=darwin GOARCH=arm64 go build -ldflags="$(LDFLAGS)" -o $(BIN_DIR)/$(STATUS)-darwin-arm64 $(STATUS_SRC)

clean:
	@echo "Cleaning binaries..."
	rm -f $(BIN_DIR)/$(ANALYZE)-* $(BIN_DIR)/$(STATUS)-* $(BIN_DIR)/$(ANALYZE)-go $(BIN_DIR)/$(STATUS)-go
	rm -f $(BIN_DIR)/$(MENUBAR_LIB).dylib $(BIN_DIR)/$(MENUBAR_LIB).h

# Menu bar app targets
menubar-lib:
	@echo "Building shared library for menu bar app..."
	go build -buildmode=c-shared -ldflags="$(LDFLAGS)" -o $(BIN_DIR)/$(MENUBAR_LIB).dylib $(MENUBAR_SRC)
	@echo "Library built: $(BIN_DIR)/$(MENUBAR_LIB).dylib"

menubar-app: menubar-lib
	@echo "Building menu bar app..."
	bash scripts/build-menubar.sh
