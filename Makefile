GOARCH ?= amd64
GO_LINUX := GOOS=linux GOARCH=$(GOARCH) CGO_ENABLED=0

.PHONY: build test-bin

# Go helpers the bash commands run. Built for Linux even when invoked on a Mac.
build:
	$(GO_LINUX) go build -o bin/trash-go ./cmd/trash
	$(GO_LINUX) go build -o bin/status-go ./cmd/status
	$(GO_LINUX) go build -o bin/analyze-go ./cmd/analyze
