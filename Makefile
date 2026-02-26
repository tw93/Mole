# Makefile for Mole

.PHONY: all build menubar clean release

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

all: build menubar

# Go binaries (analyze + status)
build:
	@echo "Building Go binaries..."
	go build -ldflags="$(LDFLAGS)" -o $(BIN_DIR)/$(ANALYZE)-go $(ANALYZE_SRC)
	go build -ldflags="$(LDFLAGS)" -o $(BIN_DIR)/$(STATUS)-go $(STATUS_SRC)

# Swift menubar binary
menubar:
	@echo "Building Swift menubar..."
	cd $(MENUBAR_SRC) && swift build -c release
	cp $(MENUBAR_SRC)/.build/release/MoleMenuBar $(BIN_DIR)/$(MENUBAR)-swift

# Release build targets (run on native architectures)
release-amd64:
	@echo "Building release binaries (amd64)..."
	GOOS=darwin GOARCH=amd64 go build -ldflags="$(LDFLAGS)" -o $(BIN_DIR)/$(ANALYZE)-darwin-amd64 $(ANALYZE_SRC)
	GOOS=darwin GOARCH=amd64 go build -ldflags="$(LDFLAGS)" -o $(BIN_DIR)/$(STATUS)-darwin-amd64 $(STATUS_SRC)
	cd $(MENUBAR_SRC) && swift build -c release --arch x86_64
	cp $(MENUBAR_SRC)/.build/release/MoleMenuBar $(BIN_DIR)/$(MENUBAR)-darwin-amd64

release-arm64:
	@echo "Building release binaries (arm64)..."
	GOOS=darwin GOARCH=arm64 go build -ldflags="$(LDFLAGS)" -o $(BIN_DIR)/$(ANALYZE)-darwin-arm64 $(ANALYZE_SRC)
	GOOS=darwin GOARCH=arm64 go build -ldflags="$(LDFLAGS)" -o $(BIN_DIR)/$(STATUS)-darwin-arm64 $(STATUS_SRC)
	cd $(MENUBAR_SRC) && swift build -c release --arch arm64
	cp $(MENUBAR_SRC)/.build/release/MoleMenuBar $(BIN_DIR)/$(MENUBAR)-darwin-arm64

clean:
	@echo "Cleaning binaries..."
	rm -f $(BIN_DIR)/$(ANALYZE)-* $(BIN_DIR)/$(STATUS)-* $(BIN_DIR)/$(MENUBAR)-*
	rm -rf $(MENUBAR_SRC)/.build
