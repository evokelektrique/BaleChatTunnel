#!/usr/bin/env bash
set -euo pipefail

repo="evokelektrique/BaleChatTunnel"
binary_name="btun"
asset_name="btun-linux-x64"

install_dir="${BTUN_INSTALL_DIR:-$HOME/.local/bin}"
profile="${BTUN_PROFILE:-$HOME/.btun-relay}"
version="${BTUN_VERSION:-latest}"
run_setup="${BTUN_RUN_SETUP:-1}"

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
need chmod
need mkdir
need mktemp

if [ "$version" = "latest" ]; then
  download_url="https://github.com/$repo/releases/latest/download/$asset_name"
else
  download_url="https://github.com/$repo/releases/download/$version/$asset_name"
fi

tmp_file="$(mktemp)"
cleanup() {
  rm -f "$tmp_file"
}
trap cleanup EXIT

say "downloading $asset_name from $repo ($version)"
curl --fail --location --show-error --progress-bar "$download_url" --output "$tmp_file"

mkdir -p "$install_dir"
chmod 0755 "$tmp_file"
mv "$tmp_file" "$install_dir/$binary_name"
trap - EXIT

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
  exit 0
fi

say "starting interactive relay setup"
say "choose role 'relay', log in to Bale when prompted, then copy the relay_public_key shown at the end"
exec "$install_dir/$binary_name" setup --profile "$profile"
