.PHONY: mtls-certs clean-mtls-certs
GOFMT_FILES?=$$(find . -name '*.go' |grep -v vendor)
GOOS?=darwin
GOARCH?=arm64

CERTS_TLS_DIR ?= testdata/tls

MAKEFLAGS += --silent

VERSION=$$(git describe --tags)

build:
	CGO_ENABLED=0 go build -trimpath -ldflags "-s -w -X main.version=$(VERSION)" -o terraform-provider-keycloak_$(VERSION)

build-debug:
	# keep debug info in the binary
	CGO_ENABLED=0 go build -gcflags "all=-N -l" -trimpath -ldflags " -X main.version=$(VERSION)" -o terraform-provider-keycloak_$(VERSION)

prepare-example:
	mkdir -p example/.terraform/plugins/terraform.local/keycloak/keycloak/5.4.0/$(GOOS)_$(GOARCH)
	mkdir -p example/terraform.d/plugins/terraform.local/keycloak/keycloak/5.4.0/$(GOOS)_$(GOARCH)
	cp terraform-provider-keycloak_* example/.terraform/plugins/terraform.local/keycloak/keycloak/5.4.0/$(GOOS)_$(GOARCH)/
	cp terraform-provider-keycloak_* example/terraform.d/plugins/terraform.local/keycloak/keycloak/5.4.0/$(GOOS)_$(GOARCH)/

build-example: build prepare-example

build-example-debug: build-debug prepare-example

run-debug:
	echo "Starting delve debugger listening on port 127.0.0.1:58772"
	dlv exec --listen=:58772 --accept-multiclient --headless "./terraform-provider-keycloak_$(VERSION)" -- -debug

local: deps user-federation-example
	echo "Starting local Keycloak environment"
	docker compose up --build -d
	./scripts/wait-for-local-keycloak.sh
	./scripts/create-terraform-client.sh

local-stop:
	echo "Stopping local Keycloak environment"
	docker compose stop

local-down:
	echo "Destroying local Keycloak environment"
	docker compose down

deps:
	./scripts/check-deps.sh

fmt:
	gofmt -w -s $(GOFMT_FILES)

test: fmtcheck vet
	go test $(TEST)

testacc: fmtcheck vet
	go test -v github.com/keycloak/terraform-provider-keycloak/keycloak
	TF_ACC=1 CHECKPOINT_DISABLE=1 go test -v -timeout 60m -parallel 4 github.com/keycloak/terraform-provider-keycloak/provider $(TESTARGS)

fmtcheck:
	lineCount=$(shell gofmt -l -s $(GOFMT_FILES) | wc -l | tr -d ' ') && exit $$lineCount

vet:
	go vet ./...

user-federation-example:
	cd custom-user-federation-example && ./gradlew shadowJar

mtls-certs:
	mkdir -p "$(CERTS_TLS_DIR)" && \
	echo ">>> Generating CA key and certificate" && \
	openssl genrsa -out "$(CERTS_TLS_DIR)/ca-key.pem" 4096 && \
	openssl req -x509 -new -key "$(CERTS_TLS_DIR)/ca-key.pem" -sha256 -days 3650 \
	  -subj "/C=US/ST=Unknown/L=Unknown/O=Unknown/OU=Unknown/CN=Dev Test Root" \
	  -out "$(CERTS_TLS_DIR)/ca-cert.pem" && \
	\
	echo ">>> Generating server key and certificate" && \
	openssl genrsa -out "$(CERTS_TLS_DIR)/server-key.pem" 2048 && \
	openssl req -new -key "$(CERTS_TLS_DIR)/server-key.pem" -subj "/C=US/ST=Unknown/L=Unknown/O=Unknown/OU=Unknown/CN=localhost" \
	  -out "$(CERTS_TLS_DIR)/server.csr" && \
	printf "basicConstraints=CA:false\nkeyUsage=critical,digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\nsubjectAltName=DNS:localhost,IP:127.0.0.1\n" > "$(CERTS_TLS_DIR)/server.ext" && \
	openssl x509 -req -in "$(CERTS_TLS_DIR)/server.csr" \
	  -CA "$(CERTS_TLS_DIR)/ca-cert.pem" -CAkey "$(CERTS_TLS_DIR)/ca-key.pem" -CAserial "$(CERTS_TLS_DIR)/ca-cert.srl" -CAcreateserial \
	  -out "$(CERTS_TLS_DIR)/server-cert.pem" -days 825 -sha256 -extfile "$(CERTS_TLS_DIR)/server.ext" && \
	\
	echo ">>> Generating trusted client key and certificate" && \
	openssl genrsa -out "$(CERTS_TLS_DIR)/client-key.pem" 2048 && \
	openssl req -new -key "$(CERTS_TLS_DIR)/client-key.pem" -subj "/C=US/ST=Unknown/L=Unknown/O=Unknown/OU=Unknown/CN=trusted-client-mtls" \
	  -out "$(CERTS_TLS_DIR)/client.csr" && \
	printf "basicConstraints=CA:false\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=clientAuth\nsubjectAltName=DNS:trusted-client-mtls\n" > "$(CERTS_TLS_DIR)/client.ext" && \
	openssl x509 -req -in "$(CERTS_TLS_DIR)/client.csr" \
	  -CA "$(CERTS_TLS_DIR)/ca-cert.pem" -CAkey "$(CERTS_TLS_DIR)/ca-key.pem" -CAserial "$(CERTS_TLS_DIR)/ca-cert.srl" \
	  -out "$(CERTS_TLS_DIR)/client-cert.pem" -days 825 -sha256 -extfile "$(CERTS_TLS_DIR)/client.ext" && \
	\
	echo ">>> Generating untrusted client key and certificate" && \
    	openssl genrsa -out "$(CERTS_TLS_DIR)/untrusted-client-key.pem" 2048 && \
    	openssl req -new -key "$(CERTS_TLS_DIR)/untrusted-client-key.pem" -subj "/CN=untrusted-client-mtls" \
    	  -out "$(CERTS_TLS_DIR)/untrusted-client.csr" && \
    	printf "basicConstraints=CA:false\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=clientAuth\nsubjectAltName=DNS:untrusted-client-mtls" > "$(CERTS_TLS_DIR)/untrusted-client.ext" && \
    	openssl x509 -req -in "$(CERTS_TLS_DIR)/untrusted-client.csr" -key "$(CERTS_TLS_DIR)/untrusted-client-key.pem"\
    	  -out "$(CERTS_TLS_DIR)/untrusted-client-cert.pem" -days 825 -sha256 -extfile "$(CERTS_TLS_DIR)/untrusted-client.ext" && \
    	\
	echo ">>> Cleaning up temporary files" && \
	rm -f "$(CERTS_TLS_DIR)/server.csr" "$(CERTS_TLS_DIR)/client.csr" "$(CERTS_TLS_DIR)/untrusted-client.csr" \
	      "$(CERTS_TLS_DIR)/server.ext" "$(CERTS_TLS_DIR)/client.ext" "$(CERTS_TLS_DIR)/untrusted-client.ext"\
	      "$(CERTS_TLS_DIR)/ca-cert.srl" && \
	echo ">>> Done. Certificates are in $(CERTS_TLS_DIR)"

clean-mtls-certs:
	echo ">>> Removing generated certs and keys in $(CERTS_TLS_DIR)" && \
	rm -f \
	  "$(CERTS_TLS_DIR)/ca-key.pem"     "$(CERTS_TLS_DIR)/ca-cert.pem" \
	  "$(CERTS_TLS_DIR)/server-key.pem" "$(CERTS_TLS_DIR)/server-cert.pem" \
	  "$(CERTS_TLS_DIR)/client-key.pem" "$(CERTS_TLS_DIR)/client-cert.pem" \
	  "$(CERTS_TLS_DIR)/untrusted-client-key.pem" "$(CERTS_TLS_DIR)/untrusted-client-cert.pem" \
	  "$(CERTS_TLS_DIR)/server.csr"     "$(CERTS_TLS_DIR)/client.csr" "$(CERTS_TLS_DIR)/untrusted-client.csr" \
	  "$(CERTS_TLS_DIR)/server.ext"     "$(CERTS_TLS_DIR)/client.ext"  "$(CERTS_TLS_DIR)/untrusted-client.ext" \
	  "$(CERTS_TLS_DIR)/ca-cert.srl" && \
	echo ">>> Done."
