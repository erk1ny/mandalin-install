#!/usr/bin/env bash
# Public entry point. Runs only after the complete script has arrived.
mandalin_bootstrap() {
  set -euo pipefail
  case "${1:-}" in
    --help) printf '%s\n' 'Mandalin: private prebuilt packages. No Git, Node, npm or Java setup required.'; return ;;
    --check) printf 'Bootstrap check: %s / %s\n' "$(uname -s)" "$(uname -m)"; return ;;
  esac
  if ! { exec 3<>/dev/tty; } 2>/dev/null; then
    printf '%s\n' 'Run setup in an interactive terminal.' >&2; return 1
  fi
  local base="${MANDALIN_BOOTSTRAP_URL:-https://raw.githubusercontent.com/erk1ny/mandalin-install/main}"
  local app_home="${MANDALIN_HOME:-$HOME/.mandalin}"
  local repo="${MANDALIN_DISTRIBUTION_REPOSITORY:-erk1ny/mandalin}"
  local os arch gh_os gh_arch stage gh candidate tag name expected actual choice selected account versions
  os=$(uname -s); arch=$(uname -m)
  [[ "$base" == https://* && "$repo" =~ ^[a-zA-Z0-9_.-]+/[a-zA-Z0-9_.-]+$ ]] || { echo 'Invalid repository or bootstrap URL.' >&2; return 1; }
  case "$os" in
    MINGW*|MSYS*)
      stage=$(mktemp -d)
      curl -fsSL --proto '=https' --proto-redir '=https' --connect-timeout 15 --max-time 120 "$base/bootstrap.ps1" -o "$stage/bootstrap.ps1"
      export MANDALIN_BOOTSTRAP_INTERACTIVE=1
      export MANDALIN_HOME="$(cygpath -w "$app_home")"
      powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$(cygpath -w "$stage/bootstrap.ps1")" <&3
      return ;;
    Darwin) os=darwin; gh_os=macOS ;;
    Linux) os=linux; gh_os=linux; getconf GNU_LIBC_VERSION >/dev/null 2>&1 || { echo 'glibc Linux is required.' >&2; return 1; } ;;
    *) echo "Unsupported OS: $os" >&2; return 1 ;;
  esac
  [[ "$app_home" == /* ]] || { echo 'MANDALIN_HOME must be absolute.' >&2; return 1; }
  export MANDALIN_HOME="$app_home" MANDALIN_DISTRIBUTION_REPOSITORY="$repo"
  case "$arch" in x86_64|amd64) arch=x64; gh_arch=amd64 ;; arm64|aarch64) arch=arm64; gh_arch=arm64 ;; *) echo 'Unsupported architecture.' >&2; return 1 ;; esac
  printf 'Install prebuilt Mandalin in %s, with Burp JAR in %s? [y/N] ' "$app_home" "${MANDALIN_BURP_DIR:-$HOME/Mandalin/Burp}" >&3
  read -r choice <&3
  case "$choice" in y|Y|yes|YES) ;; *) echo 'Cancelled.'; return 1 ;; esac
  mkdir -p "$app_home/downloads" "$app_home/versions" "$app_home/runtimes"
  gh=''
  for candidate in "$app_home"/runtimes/gh-*/gh_*/bin/gh "$app_home"/runtimes/gh-*/extracted/gh_*/bin/gh; do
    if [[ -x "$candidate" ]] && "$candidate" --version >/dev/null 2>&1; then gh="$candidate"; break; fi
  done
  if [[ -z "$gh" ]] && command -v gh >/dev/null 2>&1; then
    candidate=$(command -v gh); if "$candidate" --version >/dev/null 2>&1; then gh="$candidate"; fi
  fi
  if [[ -z "$gh" ]]; then
    local gh_version=2.102.0 gh_archive
    gh_archive="gh_${gh_version}_${gh_os}_${gh_arch}.tar.gz"
    if [[ "$os" == darwin ]]; then gh_archive="gh_${gh_version}_${gh_os}_${gh_arch}.zip"; fi
    stage=$(mktemp -d "$app_home/runtimes/gh-XXXXXXXX")
    echo 'Downloading GitHub sign-in helper...'
    curl -fsSL --proto '=https' --proto-redir '=https' --connect-timeout 15 --max-time 120 "https://github.com/cli/cli/releases/download/v$gh_version/gh_${gh_version}_checksums.txt" -o "$stage/checksums"
    curl -fSL --proto '=https' --proto-redir '=https' --connect-timeout 15 --max-time 600 "https://github.com/cli/cli/releases/download/v$gh_version/$gh_archive" -o "$stage/$gh_archive"
    expected=$(awk -v file="$gh_archive" '$2==file {print $1}' "$stage/checksums")
    if command -v sha256sum >/dev/null 2>&1; then actual=$(sha256sum "$stage/$gh_archive"); else actual=$(shasum -a 256 "$stage/$gh_archive"); fi
    [[ "$expected" =~ ^[a-f0-9]{64}$ && "${actual%% *}" == "$expected" ]] || { echo 'Helper checksum mismatch; refusing to extract or execute.' >&2; return 1; }
    tar -xf "$stage/$gh_archive" -C "$stage"
    gh="$stage/gh_${gh_version}_${gh_os}_${gh_arch}/bin/gh"
    if [[ ! -x "$gh" && -x "$stage/bin/gh" ]]; then gh="$stage/bin/gh"; fi
    "$gh" --version >/dev/null
  fi
  export MANDALIN_GH="$gh"
  until "$gh" api --hostname github.com "repos/$repo" --jq .full_name >/dev/null 2>&1; do
    account=$("$gh" api --hostname github.com user --jq .login 2>/dev/null || true)
    printf 'Private download access not verified for %s. Check invitation, token/SSO permissions or connectivity.\n' "${account:-no signed-in account}"
    printf '%s\n' '1. Retry' '2. Sign in through browser' '3. Switch saved account' '4. Cancel' >&3
    printf 'Choose [1-4]: ' >&3; read -r choice <&3
    case "$choice" in
      1) ;;
      2|3)
        if [[ -n "${GH_TOKEN:-}${GITHUB_TOKEN:-}" ]]; then
          printf 'Ignore environment token for this installer only? [y/N] ' >&3
          read -r selected <&3
          case "$selected" in y|Y|yes|YES) unset GH_TOKEN GITHUB_TOKEN ;; *) continue ;; esac
        fi
        if [[ "$choice" == 2 ]]; then
          echo 'Open the displayed link, enter the one-time code and authorize. Waiting for GitHub confirmation...'
          # Device flow only: no Git setup question, dependency, or global helper changes.
          GH_PROMPT_DISABLED=1 "$gh" auth login --hostname github.com --web <&3 || true
        else
          "$gh" auth status --hostname github.com --json hosts --jq '.hosts["github.com"][] | select(.active != true) | .login' || true
          printf 'Exact saved account above (blank to go back): ' >&3; read -r selected <&3
          if [[ "$selected" =~ ^[a-zA-Z0-9-]+$ ]]; then
            "$gh" auth switch --hostname github.com --user "$selected" &&
              "$gh" api --hostname github.com user --jq .login || true
          fi
        fi ;;
      *) echo 'Cancelled.'; return 1 ;;
    esac
  done
  echo 'Checking published packages...'
  stage=$(mktemp -d "$app_home/downloads/package-XXXXXXXX")
  "$gh" api --hostname github.com --paginate "repos/$repo/releases?per_page=100" \
    --jq '.[] | select(.draft == false and .prerelease == false) | . as $r | .assets[] | select(.state == "uploaded") | [$r.tag_name, .name] | @tsv' > "$stage/assets"
  versions=$(awk -v suffix="-$os-$arch.tar.gz" '
    $1 ~ /^v[0-9]+\.[0-9]+\.[0-9]+$/ {
      v=substr($1,2); n="mandalin-" v suffix;
      if ($2==n) jar[$1]=1; if ($2==n ".sha256") sums[$1]=1;
    } END {for (t in jar) if(sums[t]) print substr(t,2)}' "$stage/assets" | sort -t. -k1,1n -k2,2n -k3,3n)
  tag=$(printf '%s\n' "$versions" | tail -n 1)
  [[ -n "$tag" ]] || { echo "No complete prebuilt release for $os/$arch yet. Ask the maintainer to publish one; no source build attempted." >&2; return 1; }
  name="mandalin-$tag-$os-$arch.tar.gz"; tag="v$tag"
  export MANDALIN_INSTALL_TAG="$tag"
  echo "Downloading Mandalin $tag ($os/$arch)..."
  "$gh" release download "$tag" --repo "$repo" --pattern "$name" --pattern "$name.sha256" --dir "$stage"
  expected=$(awk -v file="$name" '$2==file {print $1}' "$stage/$name.sha256")
  if command -v sha256sum >/dev/null 2>&1; then actual=$(sha256sum "$stage/$name"); else actual=$(shasum -a 256 "$stage/$name"); fi
  [[ "$expected" =~ ^[a-f0-9]{64}$ && "${actual%% *}" == "$expected" ]] || { echo 'Package checksum mismatch; refusing to extract or execute.' >&2; return 1; }
  local destination
  destination=$(mktemp -d "$app_home/versions/$tag-XXXXXXXX")
  echo 'Verified. Extracting application...'
  tar -xzf "$stage/$name" -C "$destination"
  "$destination/runtime/bin/node" "$destination/installer/portable.mjs" <&3
}
mandalin_bootstrap "$@"
