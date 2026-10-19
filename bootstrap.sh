#!/usr/bin/env bash
# Public, credential-free entry point. The application repository stays private.
# Keep the entire program in a function: a partial curl download cannot start setup.
mandalin_bootstrap() {
  set -euo pipefail
  case "${1:-}" in
    --help) printf '%s\n' 'Guided Mandalin setup: macOS, glibc Linux, Windows Git Bash (WSL installs Linux).' 'Requires curl; asks before installing prerequisites, authenticating, or changing PATH.'; return ;;
    --check) printf 'Bootstrap syntax/platform check: %s / %s\n' "$(uname -s)" "$(uname -m)"; return ;;
  esac
  local base="${MANDALIN_BOOTSTRAP_URL:-https://raw.githubusercontent.com/erk1ny/mandalin-install/main}"
  case "$base" in https://*) ;; *) printf '%s\n' 'Bootstrap URL must use HTTPS.' >&2; return 1 ;; esac
  # Prompts and child processes must read the terminal, never the curl pipe.
  if ! { exec 3<>/dev/tty; } 2>/dev/null; then
    printf '%s\n' 'Run this guided installer in an interactive terminal (no unattended/yes mode).' >&2; return 1
  fi
  # Keep Bash itself on the curl pipe; only interactive children inherit the TTY.
  # Redirecting interpreter stdin would make it execute terminal input after setup.
  export MANDALIN_BOOTSTRAP_INTERACTIVE=1
  local os arch stage runtime sums archive version expected actual node_bin answer
  os=$(uname -s); arch=$(uname -m)
  case "$os" in
    MINGW*|MSYS*)
      stage=$(mktemp -d)
      curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' --connect-timeout 15 --max-time 120 "$base/bootstrap.ps1" -o "$stage/bootstrap.ps1"
      powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$(cygpath -w "$stage/bootstrap.ps1")" <&3
      return ;;
    Darwin) os=darwin ;;
    Linux)
      os=linux
      if ! getconf GNU_LIBC_VERSION >/dev/null 2>&1; then
        printf '%s\n' 'This installer requires glibc Linux. Alpine/musl is not supported by the bundled native runtime.' >&2; return 1
      fi ;;
    *) printf 'Unsupported OS: %s\n' "$os" >&2; return 1 ;;
  esac
  case "$arch" in x86_64|amd64) arch=x64 ;; arm64|aarch64) arch=arm64 ;; *) printf 'Unsupported architecture: %s\n' "$arch" >&2; return 1 ;; esac
  if command -v node >/dev/null 2>&1 && node -e 'const [a,b]=process.versions.node.split(".").map(Number); process.exit(a>22||(a===22&&b>=19)?0:1)' 2>/dev/null; then
    node_bin=$(command -v node)
  else
    printf '%s\n' 'Node.js 22.19+ is missing or cannot run. Install a checksum-verified Node 24 runtime in Mandalin’s user folder? [y/N]' >&3
    read -r answer <&3
    case "$answer" in y|Y|yes|YES) ;; *) printf '%s\n' 'Cancelled; Node was not installed.'; return 1 ;; esac
    runtime="${MANDALIN_HOME:-$HOME/.mandalin}/runtimes"
    mkdir -p "$runtime"
    stage=$(mktemp -d "$runtime/node-XXXXXXXX")
    sums="$stage/SHASUMS256.txt"
    curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' --connect-timeout 15 --max-time 120 https://nodejs.org/dist/latest-v24.x/SHASUMS256.txt -o "$sums"
    archive=$(awk -v suffix="-$os-$arch.tar.gz" '$2 ~ /^node-v24\.[0-9]+\.[0-9]+-/ && substr($2,length($2)-length(suffix)+1)==suffix {print $2}' "$sums")
    if [[ -z "$archive" || "$archive" == *$'\n'* ]]; then printf '%s\n' 'No unique Node archive for this platform.' >&2; return 1; fi
    expected=$(awk -v file="$archive" '$2==file {print $1}' "$sums")
    version=${archive#node-}; version=${version%%-*}
    printf 'Downloading Node %s for %s/%s…\n' "$version" "$os" "$arch"
    curl --fail --show-error --location --proto '=https' --proto-redir '=https' --connect-timeout 15 --max-time 600 "https://nodejs.org/dist/$version/$archive" -o "$stage/$archive"
    printf '%s\n' 'Verifying Node download...'
    if command -v sha256sum >/dev/null 2>&1; then actual=$(sha256sum "$stage/$archive"); else actual=$(shasum -a 256 "$stage/$archive"); fi
    if [[ "${actual%% *}" != "$expected" ]]; then printf '%s\n' 'Node checksum mismatch; refusing to extract or execute.' >&2; return 1; fi
    printf '%s\n' 'Extracting Node runtime...'
    tar -xzf "$stage/$archive" -C "$stage"
    node_bin="$stage/${archive%.tar.gz}/bin/node"
    printf '%s\n' 'Checking the downloaded Node runtime...'
    if ! "$node_bin" --version; then
      printf 'The downloaded Node runtime cannot run on this system. Check OS/architecture compatibility. Runtime: %s\n' "$node_bin" >&2
      return 1
    fi
  fi
  printf '%s\n' 'Downloading guided installer...'
  stage=$(mktemp -d)
  curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' --connect-timeout 15 --max-time 120 "$base/bootstrap.mjs" -o "$stage/bootstrap.mjs"
  printf '%s\n' 'Starting guided setup...'
  "$node_bin" "$stage/bootstrap.mjs" <&3
}
mandalin_bootstrap "$@"
