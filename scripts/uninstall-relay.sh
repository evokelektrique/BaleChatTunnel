#!/usr/bin/env bash
set -euo pipefail

asset_name="bale-chat-tunnel-cli-linux-x64"
binary_name="$asset_name"

install_dir="${BTUN_INSTALL_DIR:-$HOME/.local/bin}"
profile="${BTUN_PROFILE:-$HOME/.btun-relay}"
remove_profile="${BTUN_REMOVE_PROFILE:-1}"
service_name="${BTUN_SERVICE_NAME:-btun-relay}"
systemd_user_dir="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
service_file="$systemd_user_dir/$service_name.service"

say() {
  printf 'btun uninstaller: %s\n' "$*"
}

if command -v systemctl >/dev/null 2>&1; then
  if systemctl --user list-unit-files "$service_name.service" >/dev/null 2>&1 ||
    [ -f "$service_file" ]; then
    say "stopping user service $service_name"
    systemctl --user disable --now "$service_name" >/dev/null 2>&1 || true
  fi
fi

if [ -f "$service_file" ]; then
  rm -f "$service_file"
  say "removed $service_file"
fi

if command -v systemctl >/dev/null 2>&1; then
  systemctl --user daemon-reload >/dev/null 2>&1 || true
fi

if [ -f "$install_dir/$binary_name" ]; then
  rm -f "$install_dir/$binary_name"
  say "removed $install_dir/$binary_name"
fi

if [ "$remove_profile" = "0" ]; then
  say "kept relay profile $profile because BTUN_REMOVE_PROFILE=0"
elif [ -e "$profile" ]; then
  rm -rf "$profile"
  say "removed relay profile $profile"
fi

say "uninstall complete"
