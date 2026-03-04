# bearcave.sh

**bearcave.sh** is a terminal-based, locally encrypted password vault for Linux and macOS.  
All credentials are stored on your own machine — no cloud, no sync, no external service.

---

## Features

- AES-256-CBC encryption via OpenSSL with PBKDF2 (200,000 iterations)
- TOTP-based multi-factor authentication (MFA) via `oathtool`
- Secure temporary credential viewer — screen clears automatically after viewing
- One-keypress clipboard copy (`X`) — window closes immediately after copy
- Brute-force lockout after 5 failed login attempts
- Session idle timeout (5 minutes by default)
- Secure file deletion using `shred` (with zero-overwrite fallback)
- Master password is never passed as a command-line argument (no exposure in `ps`)
- Log rotation with configurable size limit
- MFA deactivation requires both master password and a valid TOTP code
- No cloud dependencies — fully offline

---

## Dependencies

| Dependency | Required | Purpose |
|---|---|---|
| `bash` 4.0+ | Yes | Shell runtime |
| `openssl` | Yes | Encryption and key derivation |
| `oathtool` | Optional | TOTP-based MFA |
| `xclip` / `xsel` / `wl-copy` / `pbcopy` | Optional | Clipboard copy feature |

### Installing dependencies

**Debian / Ubuntu**
```bash
sudo apt install openssl oathtool xclip
```

**Fedora / RHEL**
```bash
sudo dnf install openssl oathtool xclip
```

**macOS (Homebrew)**
```bash
brew install openssl oath-toolkit
# pbcopy is built into macOS — no install needed
```

---

## Installation

```bash
git clone https://github.com/Boeddelen/bearcave.sh.git
cd bearcave.sh
chmod +x bearcave.sh
./bearcave.sh
```

No build step required. bearcave.sh creates its data directory (`./bearcave/`) next to the script on first run.

---

## Usage

### First run

```
./bearcave.sh
```

From the main menu, select **1 — Create user** to set up your vault. You will be prompted to create a master password that meets the following requirements:

- At least 12 characters
- At least one uppercase letter
- At least one lowercase letter
- At least one digit
- At least one special character

### Main menu options

| Option | Description |
|---|---|
| 1 | Create a new user vault |
| 2 | Log in to an existing vault |
| 3 | Enable MFA (standalone, without an active session) |
| 4 | Disable MFA (standalone — requires master password + TOTP) |
| 5 | Delete a user and all associated data |
| 6 | Exit |

### Session menu (after login)

| Option | Description |
|---|---|
| 1 | Add a new entry |
| 2 | List all stored entries |
| 3 | Show an entry in a secure temporary view |
| 4 | Edit an existing entry |
| 5 | Delete an entry |
| 6 | Change master password |
| 7 | Enable MFA |
| 8 | Disable MFA |
| 9 | Lock and log out |
| 10 | Appearance settings |

### Viewing credentials

Selecting **Show entry** clears the terminal, displays the site, username, and password inside a framed box, then waits for input:

- Press **X** — copies the password to the clipboard and clears the screen immediately
- Press **Enter** — closes the view and clears the screen without copying

No credentials remain visible on screen after the window closes.

### Clipboard support

bearcave.sh automatically detects which clipboard tool is available:

| Tool | Environment |
|---|---|
| `xclip` | X11 (most Linux desktops) |
| `xsel` | X11 (alternative) |
| `wl-copy` | Wayland |
| `pbcopy` | macOS |

If none of these are installed, the copy option is hidden and a message is shown.

---

## Appearance settings

From the session menu, select **10 — Appearance settings** to customise the colour scheme. Three independent colour roles can each be set to any of the 7 standard terminal colours:

| Role | Controls |
|---|---|
| Border colour | All box borders, titles, separators, and the `Choice :` prompt |
| Text colour | Static menu labels and informational text inside boxes |
| Entry colour | Vault entry rows — the lines showing your stored site names |

Changes apply immediately to the screen and are saved to `bearcave/theme.conf`. The file is loaded automatically on every startup, so your colours persist across sessions. If the file is missing or deleted, all three roles revert to green.

---

## MFA setup

From the session menu, select **7 — Enable MFA**. bearcave.sh generates a TOTP secret and displays:

- The raw base32 secret (enter this manually into your authenticator app)
- An `otpauth://` URL (paste into a QR code generator if preferred)

Compatible with any TOTP authenticator app (Google Authenticator, Aegis, Bitwarden, etc.).

### Disabling MFA

Disabling MFA requires **both**:
1. Your master password
2. A valid TOTP code from your authenticator app

This prevents an attacker who has obtained only the master password from stripping the second factor silently.

---

## Data storage

bearcave.sh stores all data in a `bearcave/` directory created next to the script:

```
bearcave/
  users/
    <username>/
      vault.json.enc     # encrypted password vault
      keycheck.enc       # encrypted key verification blob
      mfa_secret.enc     # encrypted TOTP secret (if MFA is enabled)
      .failures          # failed login counter (if any)
  logs/
    bearcave.log         # activity log (no passwords are ever logged)
    bearcave.log.1       # rotated log (kept for one rotation cycle)
  tmp/                   # secure temp directory (cleaned on exit)
  theme.conf             # appearance settings (border, text, entry colours)
```

All files are created with permissions `600` (owner read/write only).  
All directories are created with permissions `700` (owner access only).

---

## Security notes

- Passwords are never written to disk in plaintext. Temporary files use `mktemp` for unpredictable names and are shredded with `shred -u -z -n 3` on deletion (zero-overwrite fallback if `shred` is unavailable).
- The master password is passed to OpenSSL via stdin (`-pass stdin`), never as a command-line argument, so it is never visible in process listings.
- The log file records login events, entry additions, and errors — but **never records passwords, usernames of entries, or any vault content**.
- TOTP verification accepts the current 30-second window plus the adjacent windows (±30 seconds) to tolerate minor clock drift between devices.
- After 5 failed login attempts, the account is locked. To unlock, remove the `.failures` file in the user's directory.

---

## Configuration

The following constants at the top of `bearcave.sh` can be adjusted:

| Variable | Default | Description |
|---|---|---|
| `ITER` | `200000` | PBKDF2 iteration count |
| `CIPHER` | `aes-256-cbc` | OpenSSL cipher |
| `MAX_LOGIN_ATTEMPTS` | `5` | Failed attempts before lockout |
| `SESSION_TIMEOUT` | `300` | Idle seconds before auto-logout |
| `LOG_MAX_BYTES` | `524288` | Log file size before rotation (512 KB) |
| `BOX_WIDTH` | `54` | Terminal UI box width in columns |

---

## Version history

| Version | Notes |
|---|---|
| 2.0 | Rewritten TUI with box-drawing characters, green theme. Fixed structural bug in vault_add_entry. Passwords passed via stdin (not process list). Temp files use mktemp. Brute-force lockout. Session timeout. TOTP clock-drift tolerance. Username validation. Log rotation. Secure shred on user deletion. MFA disable requires TOTP. Clipboard copy from viewer. Appearance settings with per-role colour customisation. Repository renamed to bearcave.sh. |
| 1.1 | Initial public release (BearCave) |

---

## Contributing

Pull requests are welcome. For significant changes, please open an issue first to discuss what you would like to change.

Please ensure any changes:
- Do not introduce plaintext password handling
- Maintain compatibility with `bash` 4.0+
- Keep all temp file operations through `mktemp`
- Add log entries for any new security-relevant actions (without logging sensitive content)

---

## Author

**Frederik Flakne**, 2025  
GitHub: [https://github.com/Boeddelen/bearcave.sh](https://github.com/Boeddelen/bearcave.sh)

---

## License

bearcave.sh is free software: you can redistribute it and/or modify it under the terms of the **GNU General Public License version 3** as published by the Free Software Foundation.

bearcave.sh is distributed in the hope that it will be useful, but **without any warranty** — without even the implied warranty of merchantability or fitness for a particular purpose. See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with this program. If not, see [https://www.gnu.org/licenses/](https://www.gnu.org/licenses/).

```
bearcave.sh - Terminal-based encrypted password vault
Copyright (C) 2025  Frederik Flakne

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program.  If not, see <https://www.gnu.org/licenses/>.
```

A full copy of the GNU General Public License v3.0 is available at:  
[https://www.gnu.org/licenses/gpl-3.0.txt](https://www.gnu.org/licenses/gpl-3.0.txt)
