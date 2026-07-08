# fpbx-backup

Safe backup + restore for a FusionPBX host. Detects the database backend
(PostgreSQL or SQLite) at runtime, captures configs, web root, TLS, and the
FreeSWITCH data tree (voicemail / recordings), encrypts at rest, and can push a
copy offsite. Restore works for same-host disaster recovery and migration to a
new host.

## What gets backed up

| Part | Path (default) | Mode |
|------|----------------|------|
| Database | from `/etc/fusionpbx/config.conf` | **always full** |
| FusionPBX config | `/etc/fusionpbx` | full or incremental |
| FreeSWITCH config | `/etc/freeswitch` | full or incremental |
| Web root | `/var/www/fusionpbx` | full or incremental |
| TLS / certs | `/etc/letsencrypt` + `/etc/freeswitch/tls` | full or incremental |
| Voicemail / recordings | `/var/lib/freeswitch` | full or incremental |

The database is always dumped in full so **any** restore point has a complete,
consistent database. Only the file tree is incremental.

## Incremental backups

Voicemail and recordings dominate disk usage but rarely change once written.
Incremental mode avoids re-copying them every run.

- A **full** (`--mode full`) starts a *chain*. Its id is the run timestamp; it is
  level `0`. A GNU tar snapshot (`state/<chain>.snar`) records file state.
- An **incremental** (`--mode incremental`) stores only files changed since the
  chain's level-0 full — level `1`, `2`, … Each reuses and updates the snapshot.
- Restore replays level `0` then every increment in order (deletions included).
- After `MAX_INCREMENTALS` increments the next run auto-starts a fresh full, so a
  chain never grows unbounded. A first-ever incremental with no chain, or a
  missing snapshot, auto-promotes to full.

Typical schedule: **weekly full, daily incremental** — see systemd timers below
(or use cron):

```
# weekly full (Sunday 02:00)
0 2 * * 0 root /opt/fpbx_backup/fpbx-backup.sh --mode full
# daily incremental (Mon–Sat 02:00)
0 2 * * 1-6 root /opt/fpbx_backup/fpbx-backup.sh --mode incremental
```

## Install

```
sudo cp -r fpbx_backup /opt/
sudo cp /opt/fpbx_backup/fpbx-backup.conf /etc/fpbx-backup.conf
sudo chmod 600 /etc/fpbx-backup.conf      # holds secrets
sudo $EDITOR /etc/fpbx-backup.conf        # set encryption + offsite
```

Dependencies (Debian): `tar gzip postgresql-client` (or `sqlite3`), plus
`age` or `gnupg` for encryption, and `awscli` / `rclone` / `rsync` for offsite.

## Usage

```
# Backup
sudo ./fpbx-backup.sh --mode full
sudo ./fpbx-backup.sh --mode incremental

# List restore points
sudo ./fpbx-restore.sh --list

# Restore latest point of a chain (same-host DR)
sudo ./fpbx-restore.sh --chain 20260707T120000Z

# Restore to a specific level
sudo ./fpbx-restore.sh --chain 20260707T120000Z --level 2

# Restore from one archive file (siblings auto-resolved)
sudo ./fpbx-restore.sh --archive /var/backups/fusionpbx/fpbx_pbx1_..._L2_...tar.age

# Migration to a fresh host
sudo ./fpbx-restore.sh --chain 20260707T120000Z --target migrate
```

Restore flags: `--db-only`, `--files-only`, `--no-services`, `--force`
(skip prompts), `--config PATH`.

## Self-test (preflight)

Run **before** trusting the setup, and it runs automatically before each
scheduled full backup. Non-destructive — safe on a live PBX.

```
sudo ./fpbx-selftest.sh
```

Checks: root, GNU tar + `--listed-incremental` support, config perms, DB detect
+ reachability + auth, source paths, `BACKUP_DIR` writable, encryption
encrypt/decrypt roundtrip (decrypt only if `AGE_IDENTITY` is set), and offsite
reachability. Exits non-zero if any check fails.

## Verify an existing backup

Validate that a chain can actually be read/decrypted/untarred — without touching
the running system:

```
sudo AGE_IDENTITY=/root/fpbx-age.key ./fpbx-restore.sh --verify --chain <id>
```

Per level it confirms: decrypts, outer tar lists, inner `files.tar.gz` is a valid
gzip tar (with file count), and a DB dump is present. Fails if any member is
corrupt or missing its database.

## Encryption

Set `ENCRYPTION=age` (recommended) or `gpg` in the config.

```
age-keygen -o fpbx-age.key           # keep the PRIVATE key OFFLINE
# public line "age1..." -> AGE_RECIPIENTS in the config
```

Archives are encrypted **to** the public recipient on the host, so the host
never needs the private key. To restore, supply the private key:

```
sudo AGE_IDENTITY=/root/fpbx-age.key ./fpbx-restore.sh --chain <id>
```

> **Keep the private age/gpg key off the FusionPBX box.** If the box is lost, the
> key restores the backups; if the key lives only on the box, the backups are
> unrecoverable.

## Offsite

Set `OFFSITE=s3|rclone|rsync` and the matching destination vars. Each finished
(encrypted) archive is pushed after the local write. Push failures are logged
but do not fail the backup — the local copy is retained.

## Retention

`RETENTION_DAYS` prunes **whole chains** whose newest member is older than the
window. A chain is never partially deleted, so an increment is never orphaned
from its full.

## Restore behavior / safety

- Prompts before overwriting (bypass with `--force`).
- Stops `SERVICES` (freeswitch, nginx, php-fpm) during restore, restarts after.
- SQLite restore keeps a timestamped `.pre-restore` copy.
- Postgres restore uses `--clean --if-exists` (idempotent) and recreates roles
  from the captured globals when run as superuser.
- Ownership is reset to `OWNER_USER:OWNER_GROUP` (default `www-data`).

## Migration notes (`--target migrate`)

The restore prints a checklist: verify DB creds in `config.conf` match the new
host's Postgres, re-point DNS/SIP domains if the IP changed, re-issue/copy TLS,
and run FusionPBX *Advanced > Upgrade* (App Defaults + Permissions).

## Scheduling with systemd

Units live in `systemd/`. Weekly full (Sunday) + daily incremental (Mon–Sat).
The full unit runs the self-test first (advisory — a failed check is logged but
never blocks the backup).

```
sudo cp systemd/fpbx-backup-*.service systemd/fpbx-backup-*.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now fpbx-backup-full.timer fpbx-backup-incremental.timer

systemctl list-timers 'fpbx-*'          # verify schedule
journalctl -u fpbx-backup-full.service  # read logs
sudo systemctl start fpbx-backup-full.service   # run one now
```

Adjust `OnCalendar=` in the `.timer` files to change timing, and the
`/opt/fpbx_backup` path in the `.service` files if installed elsewhere.

## Files

```
fpbx-backup.sh      backup entrypoint
fpbx-restore.sh     restore entrypoint (+ --verify, --list)
fpbx-selftest.sh    non-destructive preflight checks
fpbx-backup.conf    configuration (copy to /etc/fpbx-backup.conf)
lib/common.sh       logging, config load, DB detection, service control
lib/db.sh           pg/sqlite dump + restore
lib/crypto.sh       age/gpg encrypt + decrypt
lib/offsite.sh      s3/rclone/rsync push + pull
systemd/            full + incremental service/timer units
```
