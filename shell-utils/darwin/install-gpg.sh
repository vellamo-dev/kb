#!/bin/bash
# Installs GnuPG on macOS, and only the parts that are missing.
#
# Usage:
#   /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/vellamo-dev/kb/main/shell-utils/darwin/install-gpg.sh)"
#
# The script installs Homebrew when it is absent, then installs gnupg,
# pinentry-mac, and paperkey when those formulae are absent. It configures
# pinentry and GPG_TTY only when the required lines are not already present.
# It does not generate a key and does not change Git configuration.
#
# Re-running the script is safe. A second run validates the installation and
# leaves existing configuration in place.

set -euo pipefail

HOMEBREW_INSTALL_URL="https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh"
FORMULAE="gnupg pinentry-mac paperkey"

log() {
  printf '%s\n' "$*"
}

die() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

# macOS /bin/bash is 3.2. Keep the script compatible with that version.
if [[ "$(uname -s)" != "Darwin" ]]; then
  die "This installer supports macOS only."
fi

if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
  die "Run this installer as a normal user. Homebrew will ask for an administrator password if it needs one."
fi

have_command() {
  command -v "$1" >/dev/null 2>&1
}

file_contains() {
  local file="$1"
  local pattern="$2"
  [[ -f "$file" ]] && grep -F -q -- "$pattern" "$file"
}

append_line_if_missing() {
  local file="$1"
  local line="$2"
  if file_contains "$file" "$line"; then
    log "Already present in ${file}: ${line}"
    return 1
  fi
  touch "$file"
  printf '\n%s\n' "$line" >> "$file"
  log "Added to ${file}: ${line}"
  return 0
}

resolve_brew() {
  if have_command brew; then
    command -v brew
    return 0
  fi
  if [[ -x /opt/homebrew/bin/brew ]]; then
    printf '%s\n' /opt/homebrew/bin/brew
    return 0
  fi
  if [[ -x /usr/local/bin/brew ]]; then
    printf '%s\n' /usr/local/bin/brew
    return 0
  fi
  return 1
}

install_homebrew_if_missing() {
  if resolve_brew >/dev/null; then
    log "Homebrew is already installed: $(resolve_brew)"
    return 0
  fi

  log "Homebrew is not installed. Running the official Homebrew installer."
  have_command curl || die "curl is required to install Homebrew."
  NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL "$HOMEBREW_INSTALL_URL")"

  resolve_brew >/dev/null || die "Homebrew installation finished, but the brew binary was not found."
}

enable_brew_in_this_shell() {
  local brew_bin
  brew_bin="$(resolve_brew)"
  eval "$("$brew_bin" shellenv)"
  have_command brew || die "brew is not available after loading its shell environment."
}

ensure_brew_shellenv_in_profile() {
  local brew_bin line zprofile zshrc
  brew_bin="$(resolve_brew)"
  line="eval \"\$($brew_bin shellenv)\""
  zprofile="${HOME}/.zprofile"
  zshrc="${HOME}/.zshrc"

  if file_contains "$zprofile" "brew shellenv" || file_contains "$zshrc" "brew shellenv"; then
    log "Homebrew shell environment is already configured."
    return 0
  fi

  append_line_if_missing "$zprofile" "$line" || true
  log "Open a new terminal so brew is on PATH."
}

formula_installed() {
  brew list --formula "$1" >/dev/null 2>&1
}

install_missing_formulae() {
  local formula missing=()
  for formula in $FORMULAE; do
    if formula_installed "$formula"; then
      log "Already installed: ${formula}"
    else
      log "Missing: ${formula}"
      missing+=("$formula")
    fi
  done

  if [[ ${#missing[@]} -eq 0 ]]; then
    log "gnupg, pinentry-mac, and paperkey are already installed. Skipping brew update and brew install."
    return 0
  fi

  log "Updating Homebrew, then installing: ${missing[*]}"
  brew update
  brew install "${missing[@]}"
}

configure_pinentry_if_needed() {
  local gnupg_dir agent_conf pinentry_bin desired
  gnupg_dir="${HOME}/.gnupg"
  agent_conf="${gnupg_dir}/gpg-agent.conf"
  pinentry_bin="$(brew --prefix)/bin/pinentry-mac"
  desired="pinentry-program ${pinentry_bin}"

  [[ -x "$pinentry_bin" ]] || die "pinentry-mac was not found at ${pinentry_bin}."

  mkdir -p "$gnupg_dir"
  chmod 700 "$gnupg_dir"

  if [[ ! -f "$agent_conf" ]]; then
    printf '%s\n' "$desired" > "$agent_conf"
    chmod 600 "$agent_conf"
    log "Wrote ${agent_conf}."
    reload_agent
    return 0
  fi

  if file_contains "$agent_conf" "$desired"; then
    chmod 600 "$agent_conf"
    log "pinentry-mac is already configured in ${agent_conf}."
    return 0
  fi

  if grep -E -q '^[[:space:]]*pinentry-program[[:space:]]+' "$agent_conf"; then
    log "Warning: ${agent_conf} already sets a different pinentry-program. Leaving it unchanged."
    return 0
  fi

  printf '\n%s\n' "$desired" >> "$agent_conf"
  chmod 600 "$agent_conf"
  log "Appended pinentry-mac to ${agent_conf}."
  reload_agent
}

reload_agent() {
  if have_command gpgconf; then
    gpgconf --kill gpg-agent || true
    log "Reloaded gpg-agent so it reads the pinentry setting."
  fi
}

configure_gpg_tty_if_needed() {
  local zshrc line
  zshrc="${HOME}/.zshrc"
  line='export GPG_TTY="$(tty)"'

  append_line_if_missing "$zshrc" "$line" || true
  if [[ -t 1 ]]; then
    export GPG_TTY="$(tty)"
  fi
}

validate_installation() {
  local brew_prefix gpg_path pinentry_path paperkey_path
  brew_prefix="$(brew --prefix)"
  gpg_path="$(command -v gpg || true)"
  pinentry_path="$(command -v pinentry-mac || true)"
  paperkey_path="$(command -v paperkey || true)"

  [[ -n "$gpg_path" ]] || die "Validation failed: gpg is not on PATH."
  [[ -n "$pinentry_path" ]] || die "Validation failed: pinentry-mac is not on PATH."
  [[ -n "$paperkey_path" ]] || die "Validation failed: paperkey is not on PATH."

  case "$gpg_path" in
    "$brew_prefix"/*) ;;
    *) die "Validation failed: gpg resolves to ${gpg_path}, outside the Homebrew prefix ${brew_prefix}." ;;
  esac
  case "$pinentry_path" in
    "$brew_prefix"/*) ;;
    *) die "Validation failed: pinentry-mac resolves to ${pinentry_path}, outside the Homebrew prefix ${brew_prefix}." ;;
  esac

  gpg --version >/dev/null
  paperkey --version >/dev/null 2>&1 || paperkey --help >/dev/null

  log "Validated:"
  log "  gpg          ${gpg_path}"
  log "  pinentry-mac ${pinentry_path}"
  log "  paperkey     ${paperkey_path}"
  gpg --version | head -n 1
}

main() {
  log "Installing GnuPG for macOS. Existing tools and settings are left in place."
  install_homebrew_if_missing
  enable_brew_in_this_shell
  ensure_brew_shellenv_in_profile
  install_missing_formulae
  configure_pinentry_if_needed
  configure_gpg_tty_if_needed
  validate_installation
  log "Installation complete. Key generation and Git configuration are separate steps; this script does not perform them."
  log "Open a new terminal, then confirm the passphrase dialog with: echo \"pinentry test\" | gpg --clearsign"
}

main "$@"
