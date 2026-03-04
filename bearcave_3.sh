#!/usr/bin/env bash
# =============================================================================
#  BearCave - Terminal-based encrypted password vault
#  Version : 2.0
#  Author  : Frederik Flakne, 2025
#  GitHub  : https://github.com/Boeddelen/BearCave
#  Deps    : openssl, oathtool (optional, for TOTP-MFA)
# =============================================================================

set -euo pipefail
trap 'die "Unexpected error at line ${LINENO}."' ERR

# =============================================================================
#  PATHS AND GLOBAL CONFIG
# =============================================================================
SCRIPT_DIR="$(cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="${SCRIPT_DIR}/bearcave"
LOG_DIR="${BASE_DIR}/logs"
TMP_DIR="${BASE_DIR}/tmp"
USERS_DIR="${BASE_DIR}/users"
LOG_FILE="${LOG_DIR}/bearcave.log"

OPENSSL_BIN="$(command -v openssl || true)"
OATHTOOL_BIN="$(command -v oathtool || true)"

ITER=200000
CIPHER="aes-256-cbc"
MAX_LOGIN_ATTEMPTS=5
SESSION_TIMEOUT=300      # idle seconds before auto-logout
LOG_MAX_BYTES=524288     # 512 KB before log rotation
BOX_WIDTH=54             # total width of all boxes (including border chars)

UMASK_PREV="$(umask)"
umask 077

# Runtime session state
BEARCAVE_USER=""
BEARCAVE_PASS=""
LAST_ACTIVITY=0

# =============================================================================
#  COLORS  (green theme)
# =============================================================================
if command -v tput >/dev/null 2>&1 && [ -t 1 ] && [ -n "${TERM:-}" ]; then
  G="$(tput setaf 2)"                   # normal green  - row text
  BG="$(tput bold)$(tput setaf 2)"      # bold green    - borders + titles
  DG="$(tput setaf 2)"                  # dim green     - hints
  RED="$(tput setaf 1)"
  BOLD="$(tput bold)"
  RESET="$(tput sgr0)"
else
  G="" BG="" DG="" RED="" BOLD="" RESET=""
fi

# =============================================================================
#  BOX-DRAWING CHARACTERS  (UTF-8, 3 bytes each, 1 display column each)
# =============================================================================
TL=$'\xe2\x94\x8c'   # top-left     corner
TR=$'\xe2\x94\x90'   # top-right    corner
BL=$'\xe2\x94\x94'   # bottom-left  corner
BR=$'\xe2\x94\x98'   # bottom-right corner
H=$'\xe2\x94\x80'    # horizontal   line
V=$'\xe2\x94\x82'    # vertical     line
LT=$'\xe2\x94\x9c'   # left  T-junction
RT=$'\xe2\x94\xa4'   # right T-junction

# =============================================================================
#  DRAWING PRIMITIVES
#
#  ALIGNMENT RULE:
#    UTF-8 box chars are 3 bytes but occupy 1 terminal column.
#    bash ${#var} returns byte count, NOT display columns.
#    Therefore: NEVER mix box/color chars into strings used for width math.
#    All padding calculations use pure-ASCII content only.
#    Box chars are printed as literal separate printf calls, outside any
#    string whose ${#} is measured.
# =============================================================================

# hline N  --  print exactly N horizontal box chars
hline() {
  local n="$1" i
  for (( i = 0; i < n; i++ )); do printf '%s' "${H}"; done
}

# draw_top TITLE
#   Prints the top border + centred title + sub-separator:
#     +--------------------------------------------------+
#     |                     TITLE                        |
#     +--------------------------------------------------+
draw_top() {
  local title="$1"
  local inner=$(( BOX_WIDTH - 2 ))   # inner column count (pure ASCII math)
  local tlen=${#title}
  local lpad=$(( (inner - tlen - 2) / 2 ))
  local rpad=$(( inner - tlen - 2 - lpad ))

  # Top border
  printf '%s%s' "${BG}" "${TL}"; hline "${inner}"; printf '%s%s\n' "${TR}" "${RESET}"
  # Title row
  printf '%s%s%s' "${BG}" "${V}" "${RESET}"
  printf '%*s' "${lpad}" ''
  printf ' %s%s%s ' "${BG}" "${title}" "${RESET}"
  printf '%*s' "${rpad}" ''
  printf '%s%s%s\n' "${BG}" "${V}" "${RESET}"
  # Sub-separator
  printf '%s%s' "${BG}" "${LT}"; hline "${inner}"; printf '%s%s\n' "${RT}" "${RESET}"
}

# draw_row NUM TEXT
#   Prints:  |  N  text                                  |
draw_row() {
  local num="$1" text="$2"
  local inner=$(( BOX_WIDTH - 2 ))
  local content="  ${num}  ${text}"
  local clen=${#content}
  local pad=$(( inner - clen ))
  printf '%s%s%s' "${BG}" "${V}" "${RESET}"
  printf '%s%s%s' "${G}"  "${content}" "${RESET}"
  printf '%*s' "$(( pad > 0 ? pad : 0 ))" ''
  printf '%s%s%s\n' "${BG}" "${V}" "${RESET}"
}

# draw_text TEXT
#   Prints:  |  text                                     |
draw_text() {
  local text="$1"
  local inner=$(( BOX_WIDTH - 2 ))
  local content="  ${text}"
  local clen=${#content}
  local pad=$(( inner - clen ))
  printf '%s%s%s' "${BG}" "${V}" "${RESET}"
  printf '%s%s%s' "${G}"  "${content}" "${RESET}"
  printf '%*s' "$(( pad > 0 ? pad : 0 ))" ''
  printf '%s%s%s\n' "${BG}" "${V}" "${RESET}"
}

# draw_blank  --  empty row inside box
draw_blank() {
  local inner=$(( BOX_WIDTH - 2 ))
  printf '%s%s%s' "${BG}" "${V}" "${RESET}"
  printf '%*s' "${inner}" ''
  printf '%s%s%s\n' "${BG}" "${V}" "${RESET}"
}

# draw_sep  --  mid-box horizontal rule  +--...--+
draw_sep() {
  local inner=$(( BOX_WIDTH - 2 ))
  printf '%s%s' "${BG}" "${LT}"; hline "${inner}"; printf '%s%s\n' "${RT}" "${RESET}"
}

# draw_bottom  --  close the box  +--...--+
draw_bottom() {
  local inner=$(( BOX_WIDTH - 2 ))
  printf '%s%s' "${BG}" "${BL}"; hline "${inner}"; printf '%s%s\n' "${BR}" "${RESET}"
}

# =============================================================================
#  INIT
# =============================================================================
init_dirs() {
  mkdir -p "${LOG_DIR}" "${TMP_DIR}" "${USERS_DIR}"
  touch "${LOG_FILE}"
  chmod 700 "${BASE_DIR}" "${LOG_DIR}" "${TMP_DIR}" "${USERS_DIR}"
}

# =============================================================================
#  LOGGING
# =============================================================================
timestamp() { date +"%Y-%m-%d %H:%M:%S%z"; }

log() {
  local level="$1"; shift
  printf '[%s] [%s] %s\n' "$(timestamp)" "${level}" "$*" >> "${LOG_FILE}"
}

log_info()  { log "INFO"  "$*"; }
log_warn()  { log "WARN"  "$*"; }
log_error() { log "ERROR" "$*"; }

rotate_log() {
  if [ -f "${LOG_FILE}" ]; then
    local sz; sz="$(wc -c < "${LOG_FILE}" 2>/dev/null || echo 0)"
    if (( sz > LOG_MAX_BYTES )); then
      mv "${LOG_FILE}" "${LOG_FILE}.1"
      touch "${LOG_FILE}"
      chmod 600 "${LOG_FILE}"
      log_info "Log rotated."
    fi
  fi
}

# =============================================================================
#  CLEANUP
# =============================================================================
secure_rm() {
  local f="$1"
  [ -f "${f}" ] || return 0
  if command -v shred >/dev/null 2>&1; then
    shred -u -z -n 3 -- "${f}" 2>/dev/null || rm -f -- "${f}"
  else
    local sz; sz="$(wc -c < "${f}" 2>/dev/null || echo 64)"
    dd if=/dev/zero of="${f}" bs=1 count="${sz}" conv=notrunc 2>/dev/null || true
    rm -f -- "${f}"
  fi
}

cleanup() {
  if [ -d "${TMP_DIR}" ]; then
    find "${TMP_DIR}" -maxdepth 1 -type f -print0 2>/dev/null \
      | while IFS= read -r -d '' f; do secure_rm "${f}"; done
  fi
  BEARCAVE_PASS=""
  unset BEARCAVE_PASS 2>/dev/null || true
}
trap cleanup EXIT INT TERM

# =============================================================================
#  MESSAGES
# =============================================================================
die() {
  printf '\n%sFATAL: %s%s\n\n' "${RED}${BOLD}" "$*" "${RESET}" >&2
  log_error "FATAL: $*"
  exit 1
}

msg_ok()   { printf '\n%s  [ OK ]  %s%s\n'  "${BG}"  "$*" "${RESET}"; }
msg_err()  { printf '\n%s  [ !! ]  %s%s\n'  "${RED}" "$*" "${RESET}"; }
msg_warn() { printf '\n%s  [ ** ]  %s%s\n'  "${G}"   "$*" "${RESET}"; }
msg_info() { printf '\n%s  [ -- ]  %s%s\n'  "${DG}"  "$*" "${RESET}"; }

# =============================================================================
#  DEPENDENCY CHECK
# =============================================================================
check_deps() {
  if [ -z "${OPENSSL_BIN}" ]; then
    die "OpenSSL not found. Install openssl and retry."
  fi
  if ! "${OPENSSL_BIN}" enc -"${CIPHER}" -help >/dev/null 2>&1; then
    die "OpenSSL does not support cipher '${CIPHER}'."
  fi
  if [ -z "${OATHTOOL_BIN}" ]; then
    log_warn "oathtool not found. MFA unavailable."
  else
    log_info "oathtool found. MFA available."
  fi
}

# =============================================================================
#  BANNER
# =============================================================================
banner() {
  local inner=$(( BOX_WIDTH - 2 ))
  clear
  printf '\n'

  # Top border
  printf '%s%s' "${BG}" "${TL}"; hline "${inner}"; printf '%s%s\n' "${TR}" "${RESET}"

  # Line 1: "  BEARCAVE" on left, "v2.0  " on right
  # All widths are pure ASCII so ${#} is accurate here
  local l1="  BEARCAVE"
  local r1="v2.0  "
  local gap1=$(( inner - ${#l1} - ${#r1} ))
  printf '%s%s%s' "${BG}" "${V}" "${RESET}"
  printf '%s%s%s' "${BG}" "${l1}" "${RESET}"
  printf '%*s' "$(( gap1 > 0 ? gap1 : 1 ))" ''
  printf '%s%s%s' "${G}"  "${r1}" "${RESET}"
  printf '%s%s%s\n' "${BG}" "${V}" "${RESET}"

  # Line 2: subtitle centred
  local sub="Encrypted Local Password Vault"
  local slen=${#sub}
  local slpad=$(( (inner - slen) / 2 ))
  local srpad=$(( inner - slen - slpad ))
  printf '%s%s%s' "${BG}" "${V}" "${RESET}"
  printf '%*s' "${slpad}" ''
  printf '%s%s%s' "${DG}" "${sub}" "${RESET}"
  printf '%*s' "$(( srpad > 0 ? srpad : 0 ))" ''
  printf '%s%s%s\n' "${BG}" "${V}" "${RESET}"

  # Bottom border
  printf '%s%s' "${BG}" "${BL}"; hline "${inner}"; printf '%s%s\n' "${BR}" "${RESET}"
  printf '\n'
}

# =============================================================================
#  INPUT HELPERS
# =============================================================================
read_hidden() {
  local prompt="$1" varname="$2" input=""
  printf '%s  %s%s' "${G}" "${prompt}" "${RESET}"
  read -r -s input
  printf '\n'
  printf -v "${varname}" '%s' "${input}"
}

read_visible() {
  local prompt="$1" varname="$2" input=""
  printf '%s  %s%s' "${G}" "${prompt}" "${RESET}"
  read -r input
  printf -v "${varname}" '%s' "${input}"
}

prompt_choice() {
  local varname="$1" input=""
  printf '%s  Choice : %s' "${BG}" "${RESET}"
  read -r input
  printf -v "${varname}" '%s' "${input}"
}

# =============================================================================
#  VALIDATION
# =============================================================================
validate_username() {
  local u="$1"
  if [[ ! "${u}" =~ ^[a-zA-Z0-9_-]{1,32}$ ]]; then
    msg_err "Username: 1-32 chars, letters/digits/- or _ only."
    return 1
  fi
}

validate_password() {
  local pwd="$1"
  local msgs=()
  (( ${#pwd} >= 12 ))            || msgs+=("12+ characters")
  [[ "${pwd}" =~ [a-z] ]]        || msgs+=("lowercase letter")
  [[ "${pwd}" =~ [A-Z] ]]        || msgs+=("uppercase letter")
  [[ "${pwd}" =~ [0-9] ]]        || msgs+=("digit")
  [[ "${pwd}" =~ [^a-zA-Z0-9] ]] || msgs+=("special character")
  if (( ${#msgs[@]} > 0 )); then
    msg_warn "Password needs: $(IFS=', '; printf '%s' "${msgs[*]}")"
    return 1
  fi
}

# =============================================================================
#  ENCRYPTION  --  password always via stdin, never in process list
# =============================================================================
enc_file() {
  local pass="$1" src="$2" dst="$3"
  printf '%s' "${pass}" \
    | "${OPENSSL_BIN}" enc -"${CIPHER}" -pbkdf2 -iter "${ITER}" \
        -salt -in "${src}" -out "${dst}" -pass stdin
}

dec_file_to_stdout() {
  local pass="$1" src="$2"
  printf '%s' "${pass}" \
    | "${OPENSSL_BIN}" enc -"${CIPHER}" -d -pbkdf2 -iter "${ITER}" \
        -in "${src}" -pass stdin
}

# =============================================================================
#  USER DIRECTORY
# =============================================================================
user_dir()    { printf '%s/%s' "${USERS_DIR}" "$1"; }
user_exists() { [ -d "$(user_dir "$1")" ]; }

# =============================================================================
#  BRUTE-FORCE LOCKOUT
# =============================================================================
fail_file() { printf '%s/.failures' "$(user_dir "$1")"; }

record_failure() {
  local ff; ff="$(fail_file "$1")"
  local n=0
  [ -f "${ff}" ] && n="$(cat "${ff}" 2>/dev/null || echo 0)"
  printf '%d\n' $(( n + 1 )) > "${ff}"
  chmod 600 "${ff}"
}

clear_failures() { rm -f "$(fail_file "$1")"; }

check_lockout() {
  local ff; ff="$(fail_file "$1")"
  if [ -f "${ff}" ]; then
    local n; n="$(cat "${ff}" 2>/dev/null || echo 0)"
    if (( n >= MAX_LOGIN_ATTEMPTS )); then
      msg_err "Account locked after ${MAX_LOGIN_ATTEMPTS} failed attempts."
      log_warn "Locked account access attempt: $1"
      return 1
    fi
  fi
}

# =============================================================================
#  CREATE USER
# =============================================================================
create_user() {
  local username="$1"
  validate_username "${username}" || return 1

  if user_exists "${username}"; then
    msg_err "User '${username}' already exists."
    return 1
  fi

  local dir; dir="$(user_dir "${username}")"
  mkdir -p "${dir}"
  chmod 700 "${dir}"

  local pwd1 pwd2
  while true; do
    read_hidden "New master password  : " pwd1
    validate_password "${pwd1}" || continue
    read_hidden "Confirm password     : " pwd2
    if [ "${pwd1}" != "${pwd2}" ]; then
      msg_err "Passwords do not match."
      continue
    fi
    break
  done

  # Keycheck: random blob encrypted with master password (used to verify login)
  local probe; probe="$(mktemp "${TMP_DIR}/probe.XXXXXX")"
  "${OPENSSL_BIN}" rand 32 > "${probe}"
  enc_file "${pwd1}" "${probe}" "${dir}/keycheck.enc"
  secure_rm "${probe}"
  chmod 600 "${dir}/keycheck.enc"

  # Empty vault
  local vplain; vplain="$(mktemp "${TMP_DIR}/vault.XXXXXX")"
  printf '[]' > "${vplain}"
  enc_file "${pwd1}" "${vplain}" "${dir}/vault.json.enc"
  secure_rm "${vplain}"
  chmod 600 "${dir}/vault.json.enc"

  msg_ok "User '${username}' created."
  log_info "User created: ${username}"
}

# =============================================================================
#  AUTHENTICATE
# =============================================================================
auth_user() {
  local username="$1"
  validate_username "${username}" || return 1
  if ! user_exists "${username}"; then
    msg_err "User '${username}' not found."
    return 1
  fi
  check_lockout "${username}" || return 1

  local dir; dir="$(user_dir "${username}")"
  local pwd
  read_hidden "Master password : " pwd

  if ! dec_file_to_stdout "${pwd}" "${dir}/keycheck.enc" >/dev/null 2>&1; then
    msg_err "Authentication failed."
    record_failure "${username}"
    local ff; ff="$(fail_file "${username}")"
    local n; n="$(cat "${ff}" 2>/dev/null || echo 0)"
    local rem=$(( MAX_LOGIN_ATTEMPTS - n ))
    (( rem > 0 )) && msg_info "${rem} attempt(s) remaining before lockout."
    log_warn "Failed login: ${username} (attempt ${n})"
    return 2
  fi

  # MFA verification
  local mfa_file="${dir}/mfa_secret.enc"
  if [ -f "${mfa_file}" ]; then
    if [ -z "${OATHTOOL_BIN}" ]; then
      msg_err "MFA is configured but oathtool is not installed."
      log_warn "MFA required, oathtool missing: ${username}"
      return 3
    fi
    local secret
    if ! secret="$(dec_file_to_stdout "${pwd}" "${mfa_file}" 2>/dev/null)"; then
      msg_err "Could not decrypt MFA secret."
      log_error "MFA decryption failed: ${username}"
      return 4
    fi
    local code
    read_hidden "TOTP code (6 digits) : " code

    # Accept current window + adjacent windows for clock-drift tolerance
    local ec ep en
    ec="$("${OATHTOOL_BIN}" -b --totp "${secret}" 2>/dev/null || true)"
    ep="$("${OATHTOOL_BIN}" -b --totp "${secret}" \
          --now "$(date -u -d '30 seconds ago' +%Y-%m-%dT%H:%M:%S 2>/dev/null \
               || date -u -v -30S +%Y-%m-%dT%H:%M:%S 2>/dev/null \
               || echo '')" 2>/dev/null || true)"
    en="$("${OATHTOOL_BIN}" -b --totp "${secret}" \
          --now "$(date -u -d '30 seconds' +%Y-%m-%dT%H:%M:%S 2>/dev/null \
               || date -u -v +30S +%Y-%m-%dT%H:%M:%S 2>/dev/null \
               || echo '')" 2>/dev/null || true)"

    if [ "${code}" != "${ec}" ] && [ "${code}" != "${ep}" ] && [ "${code}" != "${en}" ]; then
      msg_err "Invalid TOTP code."
      record_failure "${username}"
      log_warn "MFA failure: ${username}"
      return 5
    fi
  fi

  clear_failures "${username}"
  log_info "Login OK: ${username}"
  BEARCAVE_USER="${username}"
  BEARCAVE_PASS="${pwd}"
  LAST_ACTIVITY="$(date +%s)"
  user_session
}

# =============================================================================
#  SESSION TIMEOUT
# =============================================================================
check_session_timeout() {
  local now; now="$(date +%s)"
  if (( now - LAST_ACTIVITY > SESSION_TIMEOUT )); then
    printf '\n%s  Session expired after %d minutes of inactivity.%s\n' \
      "${G}" "$(( SESSION_TIMEOUT / 60 ))" "${RESET}"
    log_info "Session timeout: ${BEARCAVE_USER}"
    BEARCAVE_PASS=""
    BEARCAVE_USER=""
    return 1
  fi
  LAST_ACTIVITY="${now}"
}

# =============================================================================
#  MFA SETUP / DISABLE
# =============================================================================
setup_mfa() {
  local username="${1:-${BEARCAVE_USER}}"
  local dir; dir="$(user_dir "${username}")"
  local pass="${BEARCAVE_PASS:-}"

  if [ -z "${OATHTOOL_BIN}" ]; then
    msg_warn "oathtool is not installed. Cannot configure TOTP-MFA."
    return 1
  fi

  if [ -z "${pass}" ]; then
    read_hidden "Master password for ${username} : " pass
    if ! dec_file_to_stdout "${pass}" "${dir}/keycheck.enc" >/dev/null 2>&1; then
      msg_err "Authentication failed."
      return 2
    fi
  fi

  # Generate base32 secret
  local secret=""
  if command -v base32 >/dev/null 2>&1; then
    secret="$("${OPENSSL_BIN}" rand 20 | base32 | tr -d '=\n')"
  elif command -v gbase32 >/dev/null 2>&1; then
    secret="$("${OPENSSL_BIN}" rand 20 | gbase32 | tr -d '=\n')"
  else
    secret="$("${OPENSSL_BIN}" rand -hex 20 | tr '[:lower:]' '[:upper:]')"
  fi

  local otpauth="otpauth://totp/BearCave:${username}?secret=${secret}&issuer=BearCave&digits=6&period=30&algorithm=SHA1"

  local tmp; tmp="$(mktemp "${TMP_DIR}/mfa.XXXXXX")"
  printf '%s' "${secret}" > "${tmp}"
  enc_file "${pass}" "${tmp}" "${dir}/mfa_secret.enc"
  secure_rm "${tmp}"
  chmod 600 "${dir}/mfa_secret.enc"

  printf '\n'
  draw_top "MFA ACTIVATED"
  draw_text "User   : ${username}"
  draw_text "Secret : ${secret}"
  draw_sep
  draw_text "Add the secret to your authenticator app."
  draw_blank
  draw_text "OTPauth URL (for QR code generators):"
  draw_text "${otpauth}"
  draw_bottom
  log_info "MFA activated: ${username}"
}

disable_mfa() {
  local username="${1:-${BEARCAVE_USER}}"
  local dir; dir="$(user_dir "${username}")"
  local pass="${BEARCAVE_PASS:-}"

  # Step 1: verify master password
  if [ -z "${pass}" ]; then
    read_hidden "Master password for ${username} : " pass
    if ! dec_file_to_stdout "${pass}" "${dir}/keycheck.enc" >/dev/null 2>&1; then
      msg_err "Authentication failed."
      return 2
    fi
  fi

  local mfa_file="${dir}/mfa_secret.enc"

  if [ ! -f "${mfa_file}" ]; then
    msg_warn "MFA was not active for '${username}'."
    return 0
  fi

  # Step 2: MFA is active — require a valid TOTP code before deactivating.
  # This prevents an attacker who has only the master password from
  # silently stripping the second factor.
  if [ -z "${OATHTOOL_BIN}" ]; then
    msg_err "MFA is active but oathtool is not installed — cannot verify."
    msg_err "Install oathtool, then try again."
    log_warn "disable_mfa blocked: oathtool missing for ${username}"
    return 3
  fi

  local secret
  if ! secret="$(dec_file_to_stdout "${pass}" "${mfa_file}" 2>/dev/null)"; then
    msg_err "Could not decrypt MFA secret."
    log_error "MFA secret decryption failed during disable_mfa: ${username}"
    return 4
  fi

  local code
  read_hidden "TOTP code to confirm MFA removal : " code

  # Accept current + adjacent windows for clock-drift tolerance
  local ec ep en
  ec="$("${OATHTOOL_BIN}" -b --totp "${secret}" 2>/dev/null || true)"
  ep="$("${OATHTOOL_BIN}" -b --totp "${secret}" \
        --now "$(date -u -d '30 seconds ago' +%Y-%m-%dT%H:%M:%S 2>/dev/null \
             || date -u -v -30S +%Y-%m-%dT%H:%M:%S 2>/dev/null \
             || echo '')" 2>/dev/null || true)"
  en="$("${OATHTOOL_BIN}" -b --totp "${secret}" \
        --now "$(date -u -d '30 seconds' +%Y-%m-%dT%H:%M:%S 2>/dev/null \
             || date -u -v +30S +%Y-%m-%dT%H:%M:%S 2>/dev/null \
             || echo '')" 2>/dev/null || true)"

  if [ "${code}" != "${ec}" ] && [ "${code}" != "${ep}" ] && [ "${code}" != "${en}" ]; then
    msg_err "Invalid TOTP code. MFA not deactivated."
    log_warn "disable_mfa rejected — wrong TOTP code: ${username}"
    return 5
  fi

  # Both factors confirmed — proceed with deactivation
  secure_rm "${mfa_file}"
  msg_ok "MFA deactivated for '${username}'."
  log_info "MFA deactivated: ${username}"
}

# =============================================================================
#  VAULT HELPERS
# =============================================================================
vault_file()  { printf '%s/vault.json.enc' "$(user_dir "$1")"; }

vault_read()  { dec_file_to_stdout "$2" "$(vault_file "$1")"; }

vault_write() {
  enc_file "$2" "$3" "$(vault_file "$1")"
  chmod 600 "$(vault_file "$1")"
}

# Parse JSON array into global ENTRIES array (one object per element)
parse_entries() {
  local json="$1"
  mapfile -t ENTRIES < <(
    printf '%s' "${json}" \
      | sed -e 's/^\[//' -e 's/\]$//' \
            -e 's/},{/}\n{/g' \
      | grep -v '^[[:space:]]*$'
  )
}

# Extract a named string field from a minimal JSON object
json_get() {
  printf '%s' "$1" \
    | grep -o "\"$2\":\"[^\"]*\"" \
    | sed "s/\"$2\":\"//;s/\"$//"
}

# Escape backslash and double-quote for embedding in JSON strings
json_esc() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }

make_entry() {
  printf '{"site":"%s","username":"%s","password":"%s"}' \
    "$(json_esc "$1")" "$(json_esc "$2")" "$(json_esc "$3")"
}

write_entries_to_vault() {
  local user="$1" pass="$2"
  local tmp; tmp="$(mktemp "${TMP_DIR}/vault.XXXXXX")"
  local first=1 e
  printf '[' > "${tmp}"
  for e in "${ENTRIES[@]}"; do
    [ -z "${e}" ] && continue
    (( first )) || printf ',' >> "${tmp}"
    printf '%s' "${e}" >> "${tmp}"
    first=0
  done
  printf ']' >> "${tmp}"
  vault_write "${user}" "${pass}" "${tmp}"
  secure_rm "${tmp}"
}

# =============================================================================
#  CLIPBOARD HELPER
#  Tries each clipboard tool in order of preference.
#  The password is passed via a pipe — never as a command-line argument.
#  Returns 0 on success, 1 if no clipboard tool is available.
# =============================================================================
copy_to_clipboard() {
  local data="$1"
  if command -v xclip >/dev/null 2>&1; then
    printf '%s' "${data}" | xclip -selection clipboard
  elif command -v xsel >/dev/null 2>&1; then
    printf '%s' "${data}" | xsel --clipboard --input
  elif command -v wl-copy >/dev/null 2>&1; then
    printf '%s' "${data}" | wl-copy
  elif command -v pbcopy >/dev/null 2>&1; then
    printf '%s' "${data}" | pbcopy
  else
    return 1
  fi
}

# =============================================================================
#  TEMPORARY ENTRY VIEWER
#  Clears screen, shows ONE entry inside a box.
#  User can press X to copy the password (screen closes immediately after),
#  or Enter to close without copying.
#  Credentials are never left visible on screen after the window closes.
# =============================================================================
show_temp_entry() {
  local site="$1" uname="$2" upass="$3"
  clear
  printf '\n'
  draw_top "VAULT ENTRY  --  CONFIDENTIAL"
  draw_text "Site     : ${site}"
  draw_text "Username : ${uname}"
  draw_text "Password : ${upass}"
  draw_sep
  if copy_to_clipboard "" 2>/dev/null || \
     command -v xclip  >/dev/null 2>&1 || \
     command -v xsel   >/dev/null 2>&1 || \
     command -v wl-copy >/dev/null 2>&1 || \
     command -v pbcopy >/dev/null 2>&1; then
    draw_text "[X] Copy password to clipboard,  [Enter] Close"
  else
    draw_text "[Enter] Close  (no clipboard tool found)"
  fi
  draw_bottom
  printf '\n'

  # Read a single keypress without requiring Enter
  local key
  read -r -n 1 key

  if [[ "${key}" =~ ^[Xx]$ ]]; then
    if copy_to_clipboard "${upass}"; then
      clear
      msg_ok "Password copied to clipboard. Screen cleared."
      msg_info "Clipboard will retain the password until you copy something else."
    else
      clear
      msg_err "No clipboard tool found (xclip, xsel, wl-copy, or pbcopy required)."
    fi
  else
    clear
    msg_info "Entry closed. Credentials cleared from display."
  fi

  # Scrub local variable
  upass=""
  printf '\n'
}

# =============================================================================
#  VAULT OPERATIONS
# =============================================================================

vault_add_entry() {
  local user="$1" pass="$2"
  local tmp; tmp="$(mktemp "${TMP_DIR}/vault.XXXXXX")"

  if ! vault_read "${user}" "${pass}" > "${tmp}" 2>/dev/null; then
    msg_err "Could not open vault."
    secure_rm "${tmp}"; return 1
  fi

  local json; json="$(cat "${tmp}")"; secure_rm "${tmp}"

  printf '\n'
  draw_top "ADD ENTRY"
  draw_bottom

  local site uname upass
  read_visible "Service / site : " site
  read_visible "Username       : " uname
  read_hidden  "Password       : " upass

  if [ -z "${site}" ] || [ -z "${uname}" ] || [ -z "${upass}" ]; then
    msg_err "All fields are required. Entry not saved."
    return 1
  fi

  parse_entries "${json}"
  ENTRIES+=("$(make_entry "${site}" "${uname}" "${upass}")")
  write_entries_to_vault "${user}" "${pass}"

  msg_ok "Entry added: ${site}"
  log_info "Entry added for ${user}: ${site}"
}

vault_list_sites() {
  local user="$1" pass="$2"
  local tmp; tmp="$(mktemp "${TMP_DIR}/vault.XXXXXX")"

  if ! vault_read "${user}" "${pass}" > "${tmp}" 2>/dev/null; then
    msg_err "Could not open vault."
    secure_rm "${tmp}"; return 1
  fi

  local json; json="$(cat "${tmp}")"; secure_rm "${tmp}"
  parse_entries "${json}"

  printf '\n'
  draw_top "STORED ENTRIES  (${#ENTRIES[@]})"

  if (( ${#ENTRIES[@]} == 0 )); then
    draw_text "Vault is empty."
  else
    local i=1 e
    for e in "${ENTRIES[@]}"; do
      [ -z "${e}" ] && continue
      draw_row "$(printf '%2d' "${i}")" \
        "$(json_get "${e}" "site")  ( $(json_get "${e}" "username") )"
      (( i++ ))
    done
  fi

  draw_bottom
}

vault_show_entry() {
  local user="$1" pass="$2"
  local tmp; tmp="$(mktemp "${TMP_DIR}/vault.XXXXXX")"

  if ! vault_read "${user}" "${pass}" > "${tmp}" 2>/dev/null; then
    msg_err "Could not open vault."
    secure_rm "${tmp}"; return 1
  fi

  local json; json="$(cat "${tmp}")"; secure_rm "${tmp}"
  parse_entries "${json}"

  if (( ${#ENTRIES[@]} == 0 )); then msg_warn "Vault is empty."; return; fi

  local q
  read_visible "Search (partial name, or Enter to list all) : " q

  local matched=()
  local e
  for e in "${ENTRIES[@]}"; do
    [ -z "${e}" ] && continue
    local site; site="$(json_get "${e}" "site")"
    if [ -z "${q}" ] || [[ "${site,,}" == *"${q,,}"* ]]; then
      matched+=("${e}")
    fi
  done

  if (( ${#matched[@]} == 0 )); then
    msg_warn "No entries matched '${q}'."
    return
  fi

  local chosen=""
  if (( ${#matched[@]} == 1 )); then
    chosen="${matched[0]}"
  else
    printf '\n'
    draw_top "SEARCH RESULTS"
    local k=1
    for e in "${matched[@]}"; do
      draw_row "$(printf '%2d' "${k}")" "$(json_get "${e}" "site")"
      (( k++ ))
    done
    draw_bottom
    local sel
    read_visible "Select number (or Enter to cancel) : " sel
    if [[ ! "${sel}" =~ ^[0-9]+$ ]] \
       || (( sel < 1 )) || (( sel > ${#matched[@]} )); then
      msg_info "Cancelled."; return
    fi
    chosen="${matched[$(( sel - 1 ))]}"
  fi

  show_temp_entry \
    "$(json_get "${chosen}" "site")" \
    "$(json_get "${chosen}" "username")" \
    "$(json_get "${chosen}" "password")"
}

vault_edit_entry() {
  local user="$1" pass="$2"
  local tmp; tmp="$(mktemp "${TMP_DIR}/vault.XXXXXX")"

  if ! vault_read "${user}" "${pass}" > "${tmp}" 2>/dev/null; then
    msg_err "Could not open vault."
    secure_rm "${tmp}"; return 1
  fi

  local json; json="$(cat "${tmp}")"; secure_rm "${tmp}"
  parse_entries "${json}"
  if (( ${#ENTRIES[@]} == 0 )); then msg_warn "Vault is empty."; return; fi

  printf '\n'
  draw_top "EDIT ENTRY"
  local i=1 e
  for e in "${ENTRIES[@]}"; do
    [ -z "${e}" ] && { (( i++ )); continue; }
    draw_row "$(printf '%2d' "${i}")" "$(json_get "${e}" "site")"
    (( i++ ))
  done
  draw_bottom

  local sel
  read_visible "Select entry number (or Enter to cancel) : " sel
  if [[ ! "${sel}" =~ ^[0-9]+$ ]] \
     || (( sel < 1 )) || (( sel > ${#ENTRIES[@]} )); then
    msg_info "Cancelled."; return
  fi

  local idx=$(( sel - 1 ))
  local cur="${ENTRIES[${idx}]}"
  local cs cu cp
  cs="$(json_get "${cur}" "site")"
  cu="$(json_get "${cur}" "username")"
  cp="$(json_get "${cur}" "password")"

  msg_info "Leave blank to keep the current value."
  local ns nu np
  read_visible "Site     [ ${cs} ] : " ns
  read_visible "Username [ ${cu} ] : " nu
  read_hidden  "Password [ hidden ] : " np

  [ -z "${ns}" ] && ns="${cs}"
  [ -z "${nu}" ] && nu="${cu}"
  [ -z "${np}" ] && np="${cp}"

  ENTRIES[${idx}]="$(make_entry "${ns}" "${nu}" "${np}")"
  write_entries_to_vault "${user}" "${pass}"

  msg_ok "Entry updated: ${ns}"
  log_info "Entry edited for ${user}: ${cs} -> ${ns}"
}

vault_delete_entry() {
  local user="$1" pass="$2"
  local tmp; tmp="$(mktemp "${TMP_DIR}/vault.XXXXXX")"

  if ! vault_read "${user}" "${pass}" > "${tmp}" 2>/dev/null; then
    msg_err "Could not open vault."
    secure_rm "${tmp}"; return 1
  fi

  local json; json="$(cat "${tmp}")"; secure_rm "${tmp}"
  parse_entries "${json}"
  if (( ${#ENTRIES[@]} == 0 )); then msg_warn "Vault is empty."; return; fi

  printf '\n'
  draw_top "DELETE ENTRY"
  local i=1 e
  for e in "${ENTRIES[@]}"; do
    [ -z "${e}" ] && { (( i++ )); continue; }
    draw_row "$(printf '%2d' "${i}")" "$(json_get "${e}" "site")"
    (( i++ ))
  done
  draw_bottom

  local sel
  read_visible "Select entry to delete (or Enter to cancel) : " sel
  if [[ ! "${sel}" =~ ^[0-9]+$ ]] \
     || (( sel < 1 )) || (( sel > ${#ENTRIES[@]} )); then
    msg_info "Cancelled."; return
  fi

  local idx=$(( sel - 1 ))
  local target; target="$(json_get "${ENTRIES[${idx}]}" "site")"
  local confirm
  read_visible "Type site name to confirm deletion [ ${target} ] : " confirm
  if [ "${confirm}" != "${target}" ]; then
    msg_warn "Confirmation did not match. Deletion cancelled."
    return
  fi

  unset 'ENTRIES[idx]'
  ENTRIES=("${ENTRIES[@]}")
  write_entries_to_vault "${user}" "${pass}"

  msg_ok "Entry deleted: ${target}"
  log_info "Entry deleted for ${user}: ${target}"
}

# =============================================================================
#  CHANGE MASTER PASSWORD
# =============================================================================
vault_change_master_password() {
  local user="${BEARCAVE_USER}"
  local dir; dir="$(user_dir "${user}")"
  local oldpwd="${BEARCAVE_PASS}"

  local new1 new2
  while true; do
    read_hidden "New master password  : " new1
    validate_password "${new1}" || continue
    read_hidden "Confirm new password : " new2
    [ "${new1}" = "${new2}" ] || { msg_err "Passwords do not match."; continue; }
    break
  done

  local vplain; vplain="$(mktemp "${TMP_DIR}/vault.XXXXXX")"
  if ! vault_read "${user}" "${oldpwd}" > "${vplain}" 2>/dev/null; then
    msg_err "Could not decrypt vault for re-encryption."
    secure_rm "${vplain}"; return 1
  fi
  vault_write "${user}" "${new1}" "${vplain}"
  secure_rm "${vplain}"

  local probe; probe="$(mktemp "${TMP_DIR}/probe.XXXXXX")"
  if ! dec_file_to_stdout "${oldpwd}" "${dir}/keycheck.enc" > "${probe}" 2>/dev/null; then
    msg_err "Could not re-encrypt keycheck file."
    secure_rm "${probe}"; return 2
  fi
  enc_file "${new1}" "${probe}" "${dir}/keycheck.enc"
  secure_rm "${probe}"

  local mfa_file="${dir}/mfa_secret.enc"
  if [ -f "${mfa_file}" ]; then
    local mfatmp; mfatmp="$(mktemp "${TMP_DIR}/mfa.XXXXXX")"
    if dec_file_to_stdout "${oldpwd}" "${mfa_file}" > "${mfatmp}" 2>/dev/null; then
      enc_file "${new1}" "${mfatmp}" "${mfa_file}"
    else
      log_warn "Could not re-encrypt MFA secret during password change: ${user}"
    fi
    secure_rm "${mfatmp}"
  fi

  BEARCAVE_PASS="${new1}"
  msg_ok "Master password updated. Session remains active."
  log_info "Master password changed: ${user}"
}

# =============================================================================
#  DELETE USER
# =============================================================================
delete_user() {
  local user="$1"
  validate_username "${user}" || return 1
  if ! user_exists "${user}"; then
    msg_err "User '${user}' does not exist."
    return 1
  fi

  printf '\n%s  WARNING: Permanently deletes all data for: %s%s\n' \
    "${RED}${BOLD}" "${user}" "${RESET}"
  local confirm
  read_visible "Type username to confirm deletion : " confirm
  if [ "${confirm}" != "${user}" ]; then
    msg_warn "Confirmation did not match. User not deleted."
    return 2
  fi

  local dir; dir="$(user_dir "${user}")"
  find "${dir}" -type f -print0 2>/dev/null \
    | while IFS= read -r -d '' f; do secure_rm "${f}"; done
  rm -rf -- "${dir}"

  msg_ok "User '${user}' deleted."
  log_info "User deleted: ${user}"
}

# =============================================================================
#  USER SESSION MENU
# =============================================================================
user_session() {
  local user="${BEARCAVE_USER}"
  local login_time; login_time="$(date +"%H:%M:%S")"

  while true; do
    check_session_timeout || break
    local pass="${BEARCAVE_PASS}"   # refresh after any password change

    printf '\n'
    draw_top "SESSION: ${user}  |  Login: ${login_time}"
    draw_row " 1" "Add entry"
    draw_row " 2" "List entries"
    draw_row " 3" "Show entry  (secure view)"
    draw_row " 4" "Edit entry"
    draw_row " 5" "Delete entry"
    draw_sep
    draw_row " 6" "Change master password"
    draw_row " 7" "Enable MFA"
    draw_row " 8" "Disable MFA"
    draw_sep
    draw_row " 9" "Lock and log out"
    draw_bottom

    local c
    prompt_choice c
    case "${c}" in
      1) vault_add_entry    "${user}" "${pass}" ;;
      2) vault_list_sites   "${user}" "${pass}" ;;
      3) vault_show_entry   "${user}" "${pass}" ;;
      4) vault_edit_entry   "${user}" "${pass}" ;;
      5) vault_delete_entry "${user}" "${pass}" ;;
      6) vault_change_master_password ;;
      7) setup_mfa   "${user}" ;;
      8) disable_mfa "${user}" ;;
      9) msg_ok "Session closed."; log_info "Logout: ${user}"; break ;;
      *) msg_warn "Invalid choice." ;;
    esac
  done

  BEARCAVE_PASS=""
  BEARCAVE_USER=""
}

# =============================================================================
#  MAIN MENU
# =============================================================================
main_menu() {
  while true; do
    banner
    draw_top "MAIN MENU"
    draw_row " 1" "Create user"
    draw_row " 2" "Log in"
    draw_sep
    draw_row " 3" "Enable MFA  (standalone)"
    draw_row " 4" "Disable MFA (standalone)"
    draw_row " 5" "Delete user"
    draw_sep
    draw_row " 6" "Exit"
    draw_bottom

    local choice
    prompt_choice choice

    case "${choice}" in
      1)
        local username
        read_visible "Username : " username
        create_user "${username}"
        ;;
      2)
        local username
        read_visible "Username : " username
        auth_user "${username}" || true
        ;;
      3)
        local username
        read_visible "Username : " username
        if user_exists "${username}"; then
          BEARCAVE_PASS=""
          setup_mfa "${username}"
        else
          msg_err "User not found."
        fi
        ;;
      4)
        local username
        read_visible "Username : " username
        if user_exists "${username}"; then
          BEARCAVE_PASS=""
          disable_mfa "${username}"
        else
          msg_err "User not found."
        fi
        ;;
      5)
        local username
        read_visible "Username : " username
        delete_user "${username}"
        ;;
      6)
        msg_ok "BearCave closed."
        log_info "BearCave shut."
        break
        ;;
      *)
        msg_warn "Invalid choice."
        ;;
    esac
  done
}

# =============================================================================
#  ENTRY POINT
# =============================================================================
init_dirs
rotate_log
check_deps
log_info "BearCave started."
main_menu
umask "${UMASK_PREV}"
