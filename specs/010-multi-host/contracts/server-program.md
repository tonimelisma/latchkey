# Contract: the Linux server program

The `latchkey` program for Linux servers (spec 010, plan D8 to D12). It speaks the agent protocol
(`specs/001-core/contracts/agent-protocol.md`) with `kind: linux`.

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/tonimelisma/latchkey/main/linux/install.sh | sh -s -- https://<relay>
```

Run as the Owner, not root. `install.sh` refuses unless: Linux, x86_64 or aarch64, systemd
(`/run/systemd/system`), cgroup v2 (`/sys/fs/cgroup/cgroup.controllers`), `curl`, `sha256sum`,
`sudo`. It finds the newest `server-v*` release of `LATCHKEY_REPO` (default
`tonimelisma/latchkey`; GitHub lists releases newest first), downloads
`latchkey-linux-<arch>` and `SHA256SUMS` over HTTPS, checks the checksum, and runs
`latchkey install --relay <relay> [extra arguments]`. `LATCHKEY_VERSION` picks a release;
`LATCHKEY_BASE_URL` (a folder with the two files) replaces GitHub, for tests.

`latchkey install --relay URL [--name NAME] [--no-service]`:

1. With `--no-service` absent: the same system checks.
2. The relay address must start with `https://` (or `http://localhost`; any `http://` only with
   `LATCHKEY_TEST_INSECURE_RELAY=1`, for tests). A different relay from the saved one pairs again.
3. Copies itself to `~/.local/lib/latchkey/latchkey` and links `~/.local/bin/latchkey` to it
   (a link or file already there that isn't Latchkey's is left alone).
4. Unless already paired with a readable key: makes a P-256 key, `POST /pair/device` (below),
   prints the relay's `/link` address and the code, polls until approved, saves the key and the
   device ID.
5. Unless `--no-service`: writes the unit with `sudo install`, `systemctl daemon-reload`,
   `enable`, `restart` (sudo reads a password from the terminal if it needs one).

## Headless pairing (relay endpoints)

`POST /pair/device` (JSON) `{"name", "kind": "linux", "public_key": "<PKIX DER, base64url>"}` →
`200 {"device_code", "user_code": "ABCD-EFGH", "verification_uri": "https://<relay>/link",
"interval": 5, "expires_in": 600}`. `400 {"error"}` for another kind or a key that isn't P-256;
`415` without JSON. There is no `verification_uri_complete`: the Owner types the code (RFC 8628
§3.3.1; security review, 2026-10-31). `user_code` letters: `BCDFGHJKLMNPQRSTVWXZ`.

`POST /pair/device/token` (JSON) `{"device_code"}` → `200 {"device_id", "name"}` once approved
(once only), else `400 {"error": "authorization_pending" | "slow_down" | "expired_token"}`.
`slow_down` when polled again within 4 seconds; the program then adds 5 seconds to its interval.

`GET /link` (signed in): the code form; a `code` in the address is ignored. `POST /link` with
`code`: the confirmation (machine name, kind, "Requested N minutes ago. The name "x" was chosen
by that machine.", the warning). `POST /link` with `code` and `confirm=1`: pairs (the machine's
name made unique as for any machine). Ten wrong codes per account within ten minutes refuse the
form until the window passes. Both POSTs need the page's CSRF token. All share the pairing
endpoints' per-address limit.

## Files on the server

| Path | What | Mode |
|---|---|---|
| `~/.local/lib/latchkey/latchkey` | the program (owned by the Owner, so it updates itself) | 755 |
| `~/.local/lib/latchkey/latchkey.previous` | the version before the last update | 755 |
| `~/.local/bin/latchkey` | link to the program | link |
| `~/.config/latchkey/settings.json` | settings (below) | 600 |
| `~/.local/share/latchkey/device.key` | P-256 key, PKCS#8 DER; refused if others can read it | 600 |
| `~/.local/share/latchkey/activity.jsonl` | activity log, one JSON object per line | 600 |
| `~/.local/share/latchkey/update.json` | last update: version, previous, confirmed, starts, skip list | 600 |
| `~/.cache/latchkey/jobs/<id>/` | each command's scratch folder (`TMPDIR`, `LATCHKEY_SCRATCH`) | 700 |
| `~/.cache/latchkey/bin/sudo` | `exec <real sudo> -n "$@"`, first on every command's `PATH` | 755 |
| `/etc/systemd/system/latchkey.service` | the unit (below) | 644 root |

XDG variables move the config, data, and cache folders. Files refuses to change any of these
(or a folder holding them), after resolving links, `..`, and a link whose target doesn't exist yet.

`settings.json`:

```json
{"relay": "https://relay.example", "device_id": "dev_…", "name": "", "shell": "on", "files": "write",
 "paused": false, "update_repo": "", "auto_update": true}
```

`shell`: `on` | `off`. `files`: `off` | `read` | `write`. A new server: Shell on, Files write
(FR-1024). `name` empty: the hostname. The service reads the file every second; the relay can't
change it (there is no message for it).

## The unit

```ini
[Unit]
Description=Latchkey: Claude's access to this server
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
User=<owner>
Environment=HOME=<home>
ExecStart=<home>/.local/lib/latchkey/latchkey run
Restart=always
RestartSec=5
Delegate=yes
TimeoutStopSec=20

[Install]
WantedBy=multi-user.target
```

`Delegate=yes` gives the program its own cgroup subtree: at start it moves itself to
`<own>/service` and puts each command in `<own>/jobs/<id>` (clone3 into the group). Stopping the
service stops everything in its group.

## Commands

`latchkey status`, `shell on|off`, `files off|read|write`, `pause`, `resume`, `rename NAME`,
`activity` (last 50 entries), `activity --check` (the last audit comparison; the service runs one
after each connection), `update` (install the newest release now, then `sudo systemctl restart
latchkey`), `uninstall`, `version`, `run` (the service). Exit status 0 on success, 1 on failure,
2 for usage.

`uninstall`: connects once and sends `goodbye` `user_disconnected` (the relay revokes the
device; the service's connection is replaced and closed 4002), then `sudo systemctl disable
--now latchkey`, `sudo rm -f` the unit, `daemon-reload`, and deletes the config, data, cache, and
program folders and its own `~/.local/bin` link.

## Tools

Shell: `shell_run` (`command`, `folder`, `wait` 1–30, `keep_minutes` 0–1440, `job`, `input`,
`enter`, `stop`) and `shell_check` (`job`, `wait` 0–30), deadline 45 s. Files: `files_find`
(`query`, `path`, `hidden`, `limit` 1–200), `files_read` (`path`, `offset`), deadline 30 s;
`files_change` (`action`: `write`, `append`, `edit`, `create_folder`, `move`, `copy`, `delete`;
`path`, `text`, `find`, `to`, `overwrite`). Results are text or one image block, never
structured content. Every answer ends with `Commands: <id> running, <id> kept until HH:MM` while
any are, and Shell answers say when cgroups are unusable.

`latchkey_log` (FR-1052 to FR-1056, plan D15): always offered, whatever Shell and Files are;
refused while paused like every call. Read-only, deadline 10 s. Arguments and answer as the
Mac's (spec 001 contracts/mcp-surface.md "`latchkey_log`"), "server" in place of "Mac":
`lines` 1–1000 (default 200), `category` one of `app`, `connection`, `pairing`, `settings`,
`pause`, `update`, `audit`. Lines are the activity log's events that carry public words (never
calls, never events from before the mark, made from server 0.1.1 on); without the log, this run's lines from memory
(at most 1000), and the header says so.

```
Latchkey's own log on this server (Latchkey 0.1.1): the newest 3 lines, newest last; times in Etc/UTC (UTC+00:00).
2026-11-03 22:02:09 app: Latchkey 0.1.1 started
2026-11-03 22:02:11 connection ERROR: Disconnected: the relay refused the connection; trying again in 2s
2026-11-03 22:02:13 connection: Connected as "homeserver"
```

Without the log: "… Latchkey's activity log isn't available just now (<why in fixed words: it isn't there, permission denied, it is a folder, it couldn't be read>), so these
are only the lines since Latchkey started." The time zone is `TZ`, else the name `/etc/localtime`
points to, else its abbreviation. Activity entries gain `category` and `public` (the words Claude
may see; absent: none).

## Releases and updates

GitHub release `server-v<VERSION>` (`linux/VERSION`) with `latchkey-linux-amd64`,
`latchkey-linux-arm64`, each `.sig`, `SHA256SUMS`, and `install.sh`. A `.sig` is base64 Ed25519
over the text `latchkey-linux-<arch> <version> <sha256 hex>\n` (the version and architecture are
signed, so an older program can't be relabelled as newer; security review, 2026-10-31). The key:
`SERVER_SIGNING_KEY` (base64 seed) in the gitignored `.env`, a copy in the maintainer's login
keychain ("Latchkey server release signing key"); the public key in
`linux/internal/update/key.go`. `linux/scripts/release.sh` publishes only a clean checkout at
`origin/main`.

Updates: 10 minutes after start and then daily (unless `auto_update` is false), the newest
`server-v*` release that is newer than the running version and not in the skip list is
downloaded, checked against the built-in key, the running program is copied to
`latchkey.previous`, the new one written, and the service exits (systemd restarts it). The new
version counts its unconfirmed starts; welcomed by the relay, it is confirmed. Not welcomed within
3 minutes, or at the third unconfirmed start, it puts `latchkey.previous` back, adds its version to
the skip list, and exits.

## Implementation choices

- PDF text: `github.com/ledongthuc/pdf` (BSD, a maintained fork of `rsc.io/pdf` with plain-text
  extraction), over `rsc.io/pdf` (no text API) and calling `pdftotext` (a package the server may
  not have). Its panics on malformed files become errors.
- Word and OpenDocument: their XML read with `archive/zip` and `encoding/xml` (no dependency).
- Images: decoded with the standard library and `golang.org/x/image/webp`, scaled with
  `x/image/draw` CatmullRom; pictures over 50 megapixels refused before decoding.
- Terminal: `github.com/creack/pty` (MIT). A job ends when its command's process exits, not when
  the terminal closes (a leftover holding the terminal would keep it open).
- The device key in a file, not the TPM: no extra dependency, and the service runs as the Owner.
