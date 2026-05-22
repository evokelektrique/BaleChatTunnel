# Bale Chat Tunnel

Bale Chat Tunnel is a VPN tunnel over Bale messenger. It carries local SOCKS5
traffic by splitting encrypted tunnel data into chunks, uploading those chunks
through Bale, downloading them on the relay side, and reassembling the original
TCP streams.

The project is built for a two-machine setup. The client machine runs the local
SOCKS5 proxy. The relay machine receives the encrypted chunks through Bale and
forwards the traffic to the internet.

```text
Browser/App -> SOCKS 127.0.0.1:1080 -> Bale Chat Tunnel
                                            |
                                            v
                              encrypted chunk files on Bale
                                            |
                                            v
                                   Relay machine -> Internet
```

The desktop app handles setup, key exchange, connection status, and local SOCKS
configuration. The `btun` command-line tool provides the same tunnel core for
servers, relays, and automation.

## Download Links / Release Page

Prebuilt downloads are published on the GitHub Releases page:

```text
https://github.com/evokelektrique/BaleChatTunnel/releases
```

Expected release artifacts:

- Linux desktop app, x64
- Windows desktop app, x64
- `btun` Linux CLI, x64
- `btun` Windows CLI, x64

If no release is available yet, build from source using the development steps
below.

## Setup

### Requirements

You need two machines:

- Client machine: the computer where your browser or application will use the
  tunnel.
- Relay machine: the computer that has normal internet access and forwards the
  traffic.

You also need:

- a Bale account available on both machines
- network access to Bale from both machines
- the Bale Chat Tunnel desktop app, or the matching `btun` CLI binary
- a copied public key from each side during setup

The default local proxy is:

```text
SOCKS5 127.0.0.1:1080
```

Configure your browser, operating system, or application to use that SOCKS5
proxy after the client is connected.

### GUI Setup

Use the desktop application when you want an interactive setup.

On the client machine:

1. Open Bale Chat Tunnel.
2. Go to Settings.
3. Initialize the profile if it has not been created yet.
4. Log in when prompted from the Home connection button.
5. Copy the client public key from Key Exchange.
6. Paste the relay public key into the Tunnel section.
7. Return to Home and connect after all checks are green.

On the relay machine:

1. Open Bale Chat Tunnel, or use the CLI if the relay has no desktop session.
2. Log in to the same Bale account.
3. Initialize a relay profile.
4. Copy the relay public key.
5. Paste the client public key into the relay profile.
6. Start relay mode and keep it running.

The client and relay must use the same session name and each side must have the
other side's public key.

### CLI Setup

Use the CLI for remote relays or scripted deployments. Replace
`PATH_TO_BINARY_FILE` with the directory that contains the downloaded `btun`
binary.

For a Linux x64 relay host, use the one-line installer:

```bash
curl -fsSL https://raw.githubusercontent.com/evokelektrique/BaleChatTunnel/master/scripts/install-relay.sh | bash
```

The installer downloads the latest `btun-linux-x64` release artifact, installs
it as `~/.local/bin/btun`, verifies the binary, and starts the relay setup
wizard with profile `~/.btun-relay`. Choose `relay` when asked for the machine
role, complete Bale login, then copy the `relay_public_key` printed by the
wizard.

Optional installer overrides:

```bash
curl -fsSL https://raw.githubusercontent.com/evokelektrique/BaleChatTunnel/master/scripts/install-relay.sh | BTUN_VERSION=v0.1.0 bash
curl -fsSL https://raw.githubusercontent.com/evokelektrique/BaleChatTunnel/master/scripts/install-relay.sh | BTUN_INSTALL_DIR=/usr/local/bin BTUN_PROFILE=/etc/btun/relay bash
curl -fsSL https://raw.githubusercontent.com/evokelektrique/BaleChatTunnel/master/scripts/install-relay.sh | BTUN_RUN_SETUP=0 bash
```

The easiest path is the interactive setup wizard. When it asks for the machine
role, enter one of the two supported values: `client` or `relay`. The wizard
prints this machine's public key and asks for the public key from the other
side.

On the relay machine:

```bash
PATH_TO_BINARY_FILE/btun setup --profile .btun-relay
```

Choose `relay` when asked for this machine's role. After setup, copy the
`relay_public_key` shown by the wizard and send it to the client machine. Relay
policy is optional and can be skipped unless you need to restrict destination
ports or DNS behavior.

On the client machine:

```bash
PATH_TO_BINARY_FILE/btun setup --profile .btun-client
```

Choose `client` when asked for this machine's role. Paste the relay public key
when the wizard asks for `Relay public key`. Copy the `client_public_key` shown
by the wizard and add it to the relay profile.

If you skipped a key during setup, add it later with:

```bash
PATH_TO_BINARY_FILE/btun init --profile .btun-client --relay-public-key RELAY_PUBLIC_KEY
PATH_TO_BINARY_FILE/btun init --profile .btun-relay --client-public-key CLIENT_PUBLIC_KEY
```

After both sides have each other's public key, start them:

```bash
PATH_TO_BINARY_FILE/btun relay --profile .btun-relay
PATH_TO_BINARY_FILE/btun client --profile .btun-client --socks-port 1080
```

### Manual CLI Setup

Use the manual commands when you want to script setup or update one value
without going through the wizard.

On the relay machine:

```bash
PATH_TO_BINARY_FILE/btun login --profile .btun-relay
PATH_TO_BINARY_FILE/btun init --profile .btun-relay
PATH_TO_BINARY_FILE/btun status --profile .btun-relay
```

Copy the relay public key shown by `status`.

On the client machine:

```bash
PATH_TO_BINARY_FILE/btun login --profile .btun-client
PATH_TO_BINARY_FILE/btun init --profile .btun-client
PATH_TO_BINARY_FILE/btun status --profile .btun-client
```

Copy the client public key shown by `status`.

Finish the key exchange:

```bash
PATH_TO_BINARY_FILE/btun init --profile .btun-client --peer-public-key RELAY_PUBLIC_KEY
PATH_TO_BINARY_FILE/btun init --profile .btun-relay --peer-public-key CLIENT_PUBLIC_KEY
```

The explicit aliases are also supported:

```bash
PATH_TO_BINARY_FILE/btun init --profile .btun-client --relay-public-key RELAY_PUBLIC_KEY
PATH_TO_BINARY_FILE/btun init --profile .btun-relay --client-public-key CLIENT_PUBLIC_KEY
```

Start the relay:

```bash
PATH_TO_BINARY_FILE/btun relay --profile .btun-relay
```

Start the client:

```bash
PATH_TO_BINARY_FILE/btun client --profile .btun-client --socks-port 1080
```

Then configure your browser or application to use:

```text
SOCKS5 127.0.0.1:1080
```

## Development

Install Flutter and make sure desktop support is enabled for your platform.

```bash
flutter pub get
flutter test
```

Useful Makefile commands:

```bash
make test
make build-linux-x64
make build-windows-x64
make build-cli-linux-x64
make build-cli-windows-x64
```

Run the Flutter app locally:

```bash
flutter run -d linux
```

Use the compiled CLI during development:

```bash
build/cli/btun-linux-x64 login
build/cli/btun-linux-x64 init
build/cli/btun-linux-x64 status
build/cli/btun-linux-x64 client
build/cli/btun-linux-x64 relay
```

## Architecture

Bale Chat Tunnel has two sides:

- Client: runs on your local machine and opens a SOCKS5 proxy.
- Relay: runs on another machine and forwards traffic to the internet.

Both sides log in to Bale, create a matching tunnel profile, exchange public
keys, and use Bale Saved Messages as the transport channel. TCP data is framed,
encrypted, batched into chunk files, uploaded by one side, downloaded by the
other side, decrypted, acknowledged, and retried when needed. Bale only sees
encrypted files.

```text
Client profile                         Relay profile
-------------                          -------------
SOCKS5 server                          Bale poller
TCP stream frames                      Download chunk files
Encrypt + upload     -> Bale ->        Decrypt + reassemble
ACK + retry          <- Bale <-        TCP relay
```

Main components:

- `lib/main.dart`: Flutter desktop UI and app controller.
- `bin/btun.dart`: command-line entry point.
- `lib/src/btun/`: tunnel protocol, crypto, SOCKS5 server, relay, transport,
  config, logging, and runtime modules.
- `packages/bale_client/`: Bale authentication, messaging, file upload, and
  download client.

Important behavior:

- X25519 keys are used for peer key exchange.
- HKDF-SHA256 derives encryption keys.
- AES-256-GCM encrypts tunnel chunks.
- TCP data is framed, batched into files, acknowledged, and retried.
- The client exposes SOCKS5 locally, usually `127.0.0.1:1080`.
- The relay applies port and private-IP policy checks before opening outbound
  TCP connections.

Because the transport is chunked file upload and download over a messenger,
latency and throughput depend on Bale upload speed, download speed, polling, and
rate limits.

## Issues & Feedback

Please use GitHub Issues for bugs, build problems, feature requests, and UI
feedback:

```text
https://github.com/evokelektrique/BaleChatTunnel/issues
```

When reporting a problem, include:

- operating system and version
- app or CLI version
- whether the problem is on the client, relay, or both
- relevant logs with secrets and keys removed

## License

MIT License.
