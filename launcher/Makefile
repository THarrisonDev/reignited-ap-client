# Reignited AP launcher — setup verifier + AP connection UI (self-contained web server).

GO      := go
GOFLAGS ?=
OUT     ?= launcher

.PHONY: vet test build build-windows build-linux

vet:
	$(GO) vet $(GOFLAGS) ./...

test:
	$(GO) test $(GOFLAGS) -v ./...

build:
	$(GO) build $(GOFLAGS) -o "$(OUT)" .

# Windows x64 build — srtap_launcher.exe.
build-windows:
	GOOS=windows GOARCH=amd64 $(GO) build $(GOFLAGS) -o srtap_launcher.exe .

# Linux x64 build — native launcher for Proton players (same installer).
build-linux:
	GOOS=linux GOARCH=amd64 $(GO) build $(GOFLAGS) -o srtap_launcher .

.PHONY: clean
clean:
	rm -f launcher srtap_launcher.exe srtap_launcher