# Reignited AP checkd — daemon that scans game saves for check progress.

GO      := go
GOFLAGS ?=
OUT     ?= checkd

.PHONY: vet test build build-windows

vet:
	$(GO) vet $(GOFLAGS) ./...

test:
	$(GO) test $(GOFLAGS) -v ./...

build:
	$(GO) build $(GOFLAGS) -o "$(OUT)" .

# Windows x64 build — the artifact players copy into the bridge folder as
# srtap_checkd.exe (see ../launcher/verify.go's "Check daemon" check).
build-windows:
	GOOS=windows GOARCH=amd64 $(GO) build $(GOFLAGS) -o srtap_checkd.exe .

.PHONY: clean
clean:
	rm -f checkd srtap_checkd.exe