# Bale Chat Tunnel

Tunnel local SOCKS5 traffic through Bale Saved Messages using a client machine
and a relay machine.

```text
Browser/App
    |
    v
SOCKS5 127.0.0.1:1080
    |
    v
client -> Bale -> relay -> Internet
```

## Features

- Flutter app for interactive setup, Bale login, key exchange, status, and logs.
- Dart CLI for relays, servers, and scripted setup.
- Encrypted chunk transport over Bale Saved Messages.
- Local SOCKS5 endpoint, defaulting to `127.0.0.1:1080`.

## Quick Start

Use one Bale account on the client and one on the relay.

1. Install and set up the relay on a Linux x64 host:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/evokelektrique/BaleChatTunnel/master/scripts/install-relay.sh)
```

Copy `relay_public_key`.

2. Set up the client with the desktop app, or with the CLI:

```bash
./bale-chat-tunnel-cli-linux-x64 setup --profile .btun-client
./bale-chat-tunnel-cli-linux-x64 client --profile .btun-client --socks-port 1080
```

Choose `client`, paste the `relay_public_key`, and copy the printed
`client_public_key`.

3. Add the client key on the relay:

```bash
bale-chat-tunnel-cli-linux-x64 init --profile ~/.btun-relay --client-public-key CLIENT_PUBLIC_KEY
systemctl --user restart btun-relay
```

4. Configure your browser, OS, or app:

```text
SOCKS5 127.0.0.1:1080
```

Useful relay commands:

```bash
bale-chat-tunnel-cli-linux-x64 account list --profile ~/.btun-relay
bale-chat-tunnel-cli-linux-x64 account add --profile ~/.btun-relay
journalctl --user -u btun-relay -f
```

<details>
<summary>Advanced installer options</summary>

```bash
BTUN_VERSION=v0.2.5 bash <(curl -fsSL https://raw.githubusercontent.com/evokelektrique/BaleChatTunnel/master/scripts/install-relay.sh)
BTUN_INSTALL_DIR=/usr/local/bin BTUN_PROFILE=/etc/btun/relay bash <(curl -fsSL https://raw.githubusercontent.com/evokelektrique/BaleChatTunnel/master/scripts/install-relay.sh)
BTUN_RUN_SETUP=0 bash <(curl -fsSL https://raw.githubusercontent.com/evokelektrique/BaleChatTunnel/master/scripts/install-relay.sh)
BTUN_INSTALL_SERVICE=0 bash <(curl -fsSL https://raw.githubusercontent.com/evokelektrique/BaleChatTunnel/master/scripts/install-relay.sh)
BTUN_ENABLE_SERVICE=0 bash <(curl -fsSL https://raw.githubusercontent.com/evokelektrique/BaleChatTunnel/master/scripts/install-relay.sh)
```

Uninstall relay service, binary, and default relay profile:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/evokelektrique/BaleChatTunnel/master/scripts/uninstall-relay.sh)
```

Set `BTUN_REMOVE_PROFILE=0` to keep `~/.btun-relay`.

</details>

## Usage

Common CLI commands:

```text
./bale-chat-tunnel-cli-linux-x64 setup
./bale-chat-tunnel-cli-linux-x64 status
./bale-chat-tunnel-cli-linux-x64 relay
./bale-chat-tunnel-cli-linux-x64 client --socks-port 1080
```

Use the desktop app for the same setup flow from Settings and Home.

## Configuration

Profiles store tunnel config, Bale session state, and local runtime state. The
default CLI profile is `.btun`; this README uses `.btun-client` and
`.btun-relay` to keep roles separate.

Important defaults:

| Setting | Default |
| --- | --- |
| SOCKS endpoint | `127.0.0.1:1080` |
| Transport | Adaptive |

Use matching session IDs on both profiles, and make sure each profile has the
other side's public key.

## Development

Requirements:

- Flutter/Dart compatible with SDK `^3.11.0`.
- For Linux desktop builds: `clang`, `cmake`, `ninja-build`, `pkg-config`,
  `libgtk-3-dev`, and `liblzma-dev`.

Build from source:

```bash
git clone https://github.com/evokelektrique/BaleChatTunnel.git
cd BaleChatTunnel
make pub-get
make build-cli-linux-x64
```

Run the Flutter app:

```bash
flutter run -d linux
```

Build targets:

```bash
make build-linux-x64
make build-windows-x64
make build-android-apk
make build-cli-linux-x64
make build-cli-windows-x64
```

Main code locations:

- `lib/main.dart`: Flutter app.
- `bin/`: CLI entry point.
- `lib/src/btun/`: tunnel runtime, protocol, SOCKS5 server, relay, config, and transport.
- `packages/bale_client/`: Bale authentication, messaging, and file APIs.
- `scripts/install-relay.sh`: Linux x64 relay installer.
- `scripts/uninstall-relay.sh`: Linux x64 relay uninstaller.

## Testing

```bash
make analyze
make test
```

`make test` runs the root Flutter tests and `packages/bale_client` tests.

## Troubleshooting

- Confirm both machines can reach Bale.
- Confirm both profiles use the same session ID.
- Confirm both profiles have the other side's public key.
- Confirm your app is using `SOCKS5 127.0.0.1:1080`.
- Check relay logs with `journalctl --user -u btun-relay -f` when using the installer service.

## Contributing

Use GitHub Issues for bugs, build problems, feature requests, and UI feedback:

https://github.com/evokelektrique/BaleChatTunnel/issues

## License

MIT License.
