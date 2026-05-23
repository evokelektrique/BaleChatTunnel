#!/usr/bin/env bash
set -euo pipefail

repo="evokelektrique/BaleChatTunnel"
binary_name="btun"
asset_name="bale-chat-tunnel-cli-linux-x64"
legacy_asset_name="btun-linux-x64"

install_dir="${BTUN_INSTALL_DIR:-$HOME/.local/bin}"
profile="${BTUN_PROFILE:-$HOME/.btun-relay}"
version="${BTUN_VERSION:-latest}"
run_setup="${BTUN_RUN_SETUP:-1}"
install_service="${BTUN_INSTALL_SERVICE:-1}"
enable_service_was_set="${BTUN_ENABLE_SERVICE+x}"
enable_service="${BTUN_ENABLE_SERVICE:-1}"
service_name="${BTUN_SERVICE_NAME:-btun-relay}"
systemd_user_dir="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
service_file="$systemd_user_dir/$service_name.service"

say() {
  printf 'btun installer: %s\n' "$*"
}

need() {
  if ! command -v "$1" >/dev/null 2>&1; then
    say "missing required command: $1"
    exit 1
  fi
}

case "$(uname -s)" in
  Linux) ;;
  *)
    say "this installer currently supports Linux x64 relay hosts only"
    exit 1
    ;;
esac

case "$(uname -m)" in
  x86_64|amd64) ;;
  *)
    say "unsupported CPU architecture: $(uname -m)"
    exit 1
    ;;
esac

need curl
need install
need mkdir
need mktemp

install_systemd_service() {
  if [ "$install_service" = "0" ]; then
    say "systemd service skipped because BTUN_INSTALL_SERVICE=0"
    return 0
  fi

  if ! command -v systemctl >/dev/null 2>&1; then
    say "systemctl not found; skipping systemd service installation"
    return 0
  fi

  mkdir -p "$systemd_user_dir"
  cat >"$service_file" <<EOF
[Unit]
Description=Bale Chat Tunnel relay

[Service]
Type=simple
ExecStart="$install_dir/$binary_name" relay --profile "$profile"
Restart=always
RestartSec=5

[Install]
WantedBy=default.target
EOF

  say "installed user systemd service $service_file"

  if ! systemctl --user daemon-reload; then
    say "systemd user manager is not available; start later with: systemctl --user enable --now $service_name"
    return 0
  fi

  if [ "$enable_service" = "0" ]; then
    say "service enable/start skipped because BTUN_ENABLE_SERVICE=0"
    say "start later with: systemctl --user enable --now $service_name"
    return 0
  fi

  if systemctl --user enable --now "$service_name"; then
    say "service enabled and started: $service_name"
    say "check logs with: journalctl --user -u $service_name -f"
  else
    say "could not enable/start service automatically"
    say "try later with: systemctl --user enable --now $service_name"
  fi
}

release_base="https://github.com/$repo/releases"
if [ "$version" = "latest" ]; then
  download_base="$release_base/latest/download"
else
  download_base="$release_base/download/$version"
fi

tmp_file="$(mktemp)"
cleanup() {
  rm -f "$tmp_file"
}
trap cleanup EXIT

say "downloading $asset_name from $repo ($version)"
if ! curl --fail --location --show-error --progress-bar "$download_base/$asset_name" --output "$tmp_file"; then
  say "could not download $asset_name; trying legacy asset name $legacy_asset_name"
  curl --fail --location --show-error --progress-bar "$download_base/$legacy_asset_name" --output "$tmp_file"
fi

mkdir -p "$install_dir"
install -m 0755 "$tmp_file" "$install_dir/$binary_name"

say "installed $install_dir/$binary_name"
"$install_dir/$binary_name" help >/dev/null

case ":$PATH:" in
  *":$install_dir:"*) ;;
  *)
    say "$install_dir is not on PATH"
    say "add this to your shell profile: export PATH=\"$install_dir:\$PATH\""
    ;;
esac

say "version source: $version"
say "relay profile: $profile"

if [ "$run_setup" = "0" ]; then
  say "setup skipped because BTUN_RUN_SETUP=0"
  say "run: $install_dir/$binary_name setup --profile $profile"
  if [ -z "$enable_service_was_set" ]; then
    enable_service=0
  fi
  install_systemd_service
  exit 0
fi

say "starting interactive relay setup"
say "choose role 'relay', log in to Bale when prompted, then copy the relay_public_key shown at the end"
if [ -r /dev/tty ]; then
  "$install_dir/$binary_name" setup --profile "$profile" </dev/tty
  install_systemd_service
  exit 0
fi

say "no interactive terminal is available for setup"
say "run: $install_dir/$binary_name setup --profile $profile"
exit 1
