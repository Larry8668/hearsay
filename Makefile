# hearsay — build, bundle and sign into build/hearsay.app
#
#   make            build + bundle + sign (release)
#   make run        build then launch the app
#   make test       run unit tests (transcript merge, formatting)
#   make identity   create the stable self-signed "hearsay-dev" code-signing identity (once)
#   make probe      run the CLI display probe (creates + removes a virtual display)
#   make clean

APP_NAME     := hearsay
BUNDLE_ID    := dev.hearsay.app
CONFIG       ?= release
BUILD_DIR    := build
APP          := $(BUILD_DIR)/$(APP_NAME).app
CONTENTS     := $(APP)/Contents
BIN          := .build/$(CONFIG)/$(APP_NAME)

# A STABLE identity is required: ad-hoc signing changes the code hash every build and macOS
# silently revokes the Microphone / System Audio grants. `make identity` creates "hearsay-dev".
KEYCHAIN := $(HOME)/Library/Keychains/hearsay-dev.keychain-db
KEYCHAIN_PW := hearsay
SIGN_IDENTITY ?= $(shell security find-identity -v -p codesigning 2>/dev/null | grep -q '"hearsay-dev"' && echo hearsay-dev || echo -)

VERSION := $(shell /usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist 2>/dev/null || echo 0.0.0)
ZIP := $(BUILD_DIR)/hearsay-$(VERSION).zip

.PHONY: all build bundle sign run test clean identity release

all: bundle

build:
	swift build -c $(CONFIG) --product $(APP_NAME)

bundle: build
	@rm -rf "$(APP)"
	@mkdir -p "$(CONTENTS)/MacOS" "$(CONTENTS)/Resources"
	@cp "$(BIN)" "$(CONTENTS)/MacOS/$(APP_NAME)"
	@cp Resources/Info.plist "$(CONTENTS)/Info.plist"
	@cp Resources/AppIcon.icns "$(CONTENTS)/Resources/AppIcon.icns"
	@printf 'APPL????' > "$(CONTENTS)/PkgInfo"
	@$(MAKE) --no-print-directory sign

sign:
ifeq ($(SIGN_IDENTITY),-)
	@echo "WARNING: no 'hearsay-dev' identity found; signing AD-HOC. Screen Recording permission"
	@echo "         will be revoked on every rebuild. Run: make identity"
endif
	@[ -f "$(KEYCHAIN)" ] && security unlock-keychain -p $(KEYCHAIN_PW) "$(KEYCHAIN)" 2>/dev/null || true
	codesign --force --deep --timestamp=none --sign "$(SIGN_IDENTITY)" \
	  --identifier "$(BUNDLE_ID)" "$(APP)"
	@codesign --verify --verbose=2 "$(APP)" && echo "signed $(APP) with '$(SIGN_IDENTITY)'"

run: bundle
	open "$(APP)"

test:
	swift test

# Zip for GitHub Releases / the Homebrew cask. Prints the sha256 the cask needs.
release: bundle
	@rm -f "$(ZIP)"
	ditto -c -k --keepParent --norsrc --noextattr "$(APP)" "$(ZIP)"
	@echo "sha256: $$(shasum -a 256 "$(ZIP)" | cut -d' ' -f1)"
	@echo "$(ZIP)"

clean:
	rm -rf .build "$(BUILD_DIR)"

# Creates a self-signed code-signing certificate + key in a DEDICATED keychain
# (~/Library/Keychains/hearsay-dev.keychain-db, password "hearsay") whose key partition list
# lets codesign use it without GUI prompts. Trusted for code signing at user level. No sudo.
# Idempotent.
identity:
	@if security find-identity -v -p codesigning | grep -q '"hearsay-dev"'; then \
	  echo "identity 'hearsay-dev' already exists"; exit 0; fi; \
	set -e; D=$$(mktemp -d); \
	printf '%s\n' '[req]' 'distinguished_name=dn' 'x509_extensions=ext' 'prompt=no' \
	  '[dn]' 'CN=hearsay-dev' \
	  '[ext]' 'basicConstraints=critical,CA:FALSE' 'keyUsage=critical,digitalSignature' \
	  'extendedKeyUsage=critical,codeSigning' > $$D/openssl.cnf; \
	openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config $$D/openssl.cnf \
	  -keyout $$D/key.pem -out $$D/cert.pem 2>/dev/null; \
	openssl pkcs12 -export -legacy -inkey $$D/key.pem -in $$D/cert.pem -out $$D/id.p12 -passout pass:tmp123 2>/dev/null \
	  || openssl pkcs12 -export -inkey $$D/key.pem -in $$D/cert.pem -out $$D/id.p12 -passout pass:tmp123; \
	[ -f "$(KEYCHAIN)" ] || security create-keychain -p $(KEYCHAIN_PW) "$(KEYCHAIN)" </dev/null; \
	security set-keychain-settings "$(KEYCHAIN)"; \
	security unlock-keychain -p $(KEYCHAIN_PW) "$(KEYCHAIN)"; \
	security import $$D/id.p12 -k "$(KEYCHAIN)" -P tmp123 -T /usr/bin/codesign -T /usr/bin/security </dev/null; \
	security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k $(KEYCHAIN_PW) "$(KEYCHAIN)" </dev/null >/dev/null; \
	security list-keychains -d user -s $$(security list-keychains -d user | tr -d '"') "$(KEYCHAIN)" </dev/null; \
	security add-trusted-cert -p codeSign -k "$(HOME)/Library/Keychains/login.keychain-db" $$D/cert.pem </dev/null; \
	rm -rf $$D; \
	security find-identity -v -p codesigning | grep hearsay-dev
