BALE_CLIENT_DIR := packages/bale_client
BALE_SESSION ?= session.bale_client.json
BTUN_CLI_DIR ?= build/cli
BTUN_LINUX_X64 ?= $(BTUN_CLI_DIR)/btun-linux-x64
BTUN_WINDOWS_X64 ?= $(BTUN_CLI_DIR)/btun-windows-x64.exe

.PHONY: help pub-get analyze test test-root analyze-client test-client format-client \
	bale-login bale-status bale-peers bale-listen bale-logout \
	btun-login btun-init btun-status btun-client btun-relay btun-http-test \
	btun-upload-test build-linux-x64 build-windows-x64 build-android-apk \
	build-cli-linux-x64 build-cli-windows-x64 \
	check-cli-linux-x64 check-cli-windows-x64

help:
	@printf '%s\n' 'Bale Chat Tunnel commands'
	@printf '%s\n' ''
	@printf '%s\n' 'Setup and checks:'
	@printf '%s\n' '  make pub-get          Fetch Flutter/root dependencies, including the local bale_client path package.'
	@printf '%s\n' '  make analyze          Analyze the Flutter app and bale_client package.'
	@printf '%s\n' '  make test             Run Flutter/root tests and bale_client package tests.'
	@printf '%s\n' '  make analyze-client   Run dart analyze for packages/bale_client.'
	@printf '%s\n' '  make test-client      Run package tests for packages/bale_client.'
	@printf '%s\n' '  make format-client    Format bale_client lib/bin/test Dart files.'
	@printf '%s\n' '  make build-linux-x64  Build the Flutter Linux x64 desktop app.'
	@printf '%s\n' '  make build-windows-x64 Build the Flutter Windows x64 desktop app.'
	@printf '%s\n' '  make build-android-apk Build the Flutter Android release APK.'
	@printf '%s\n' '  make build-cli-linux-x64 Compile the btun CLI for the current Linux x64 runner.'
	@printf '%s\n' '  make build-cli-windows-x64 Compile the btun CLI for the current Windows x64 runner.'
	@printf '%s\n' ''
	@printf '%s\n' 'Bale CLI via make:'
	@printf '%s\n' '  make bale-login       Interactive phone login and save session.'
	@printf '%s\n' '  make bale-status      Show saved session info.'
	@printf '%s\n' '  make bale-peers       List contacts/peer IDs from Bale.'
	@printf '%s\n' '  make bale-listen      Connect and print incoming updates.'
	@printf '%s\n' '  make bale-logout      Clear the saved session locally.'
	@printf '%s\n' ''
	@printf '%s\n' 'BTun CLI:'
	@printf '%s\n' '  make btun-login       Login and save .btun/session.json.'
	@printf '%s\n' '  make btun-init        Create/update .btun/config.json.'
	@printf '%s\n' '  make btun-status      Show profile and key status.'
	@printf '%s\n' '  make btun-relay       Run Saved Messages relay.'
	@printf '%s\n' '  make btun-client      Run SOCKS5 client on 127.0.0.1:1080.'
	@printf '%s\n' '  make btun-http-test   Send hardcoded HTTP request through tunnel.'
	@printf '%s\n' '  make btun-upload-test Verify Bale Saved Messages file upload/download.'
	@printf '%s\n' '  make check-cli-linux-x64 Run the compiled Linux CLI help command.'
	@printf '%s\n' '  make check-cli-windows-x64 Run the compiled Windows CLI help command.'
	@printf '%s\n' ''
	@printf '%s\n' 'Direct CLI equivalents:'
	@printf '%s\n' '  BALE_SESSION=$(BALE_SESSION) dart run bale_client:bale_client_cli login'
	@printf '%s\n' '  BALE_SESSION=$(BALE_SESSION) dart run bale_client:bale_client_cli status'
	@printf '%s\n' '  BALE_SESSION=$(BALE_SESSION) dart run bale_client:bale_client_cli peers'
	@printf '%s\n' '  BALE_SESSION=$(BALE_SESSION) dart run bale_client:bale_client_cli listen'
	@printf '%s\n' '  BALE_SESSION=$(BALE_SESSION) dart run bale_client:bale_client_cli send <private|group> <peer-id> <text...>'
	@printf '%s\n' '  BALE_SESSION=$(BALE_SESSION) dart run bale_client:bale_client_cli send-file <private|group> <peer-id> <path> [caption...]'
	@printf '%s\n' '  BALE_SESSION=$(BALE_SESSION) dart run bale_client:bale_client_cli download <file-id> <access-hash> <output-path>'
	@printf '%s\n' '  BALE_SESSION=$(BALE_SESSION) dart run bale_client:bale_client_cli logout [--remote]'
	@printf '%s\n' ''
	@printf '%s\n' 'Override session file with: make bale-peers BALE_SESSION=/tmp/bale-session.json'

pub-get:
	flutter pub get

analyze:
	flutter analyze
	cd $(BALE_CLIENT_DIR) && dart analyze

test: test-root test-client

test-root:
	flutter test

analyze-client:
	cd $(BALE_CLIENT_DIR) && dart analyze

test-client:
	cd $(BALE_CLIENT_DIR) && dart test

format-client:
	dart format $(BALE_CLIENT_DIR)/lib $(BALE_CLIENT_DIR)/bin $(BALE_CLIENT_DIR)/test

bale-login:
	BALE_SESSION=$(BALE_SESSION) dart run bale_client:bale_client_cli login

bale-status:
	BALE_SESSION=$(BALE_SESSION) dart run bale_client:bale_client_cli status

bale-peers:
	BALE_SESSION=$(BALE_SESSION) dart run bale_client:bale_client_cli peers

bale-listen:
	BALE_SESSION=$(BALE_SESSION) dart run bale_client:bale_client_cli listen

bale-logout:
	BALE_SESSION=$(BALE_SESSION) dart run bale_client:bale_client_cli logout

btun-login:
	dart run bale_chat_tunnel:btun login

btun-init:
	dart run bale_chat_tunnel:btun init

btun-status:
	dart run bale_chat_tunnel:btun status

btun-client:
	dart run bale_chat_tunnel:btun client

btun-relay:
	dart run bale_chat_tunnel:btun relay

btun-http-test:
	dart run bale_chat_tunnel:btun http-test

btun-upload-test:
	dart run bale_chat_tunnel:btun upload-test

build-linux-x64:
	flutter config --enable-linux-desktop
	flutter build linux --release

build-windows-x64:
	flutter config --enable-windows-desktop
	flutter build windows --release

build-android-apk:
	flutter build apk --release

build-cli-linux-x64:
	mkdir -p $(BTUN_CLI_DIR)
	dart compile exe bin/btun.dart -o $(BTUN_LINUX_X64)

build-cli-windows-x64:
	mkdir -p $(BTUN_CLI_DIR)
	dart compile exe bin/btun.dart -o $(BTUN_WINDOWS_X64)

check-cli-linux-x64: build-cli-linux-x64
	./$(BTUN_LINUX_X64) help

check-cli-windows-x64: build-cli-windows-x64
	./$(BTUN_WINDOWS_X64) help
