# Documenta

Shared documents, fill-in templates and bulk records, edited in the browser with ONLYOFFICE, with Telegram notifications for your team's groups. This repository holds the installer; everything runs on your own server.

## Requirements

- A Linux server (Ubuntu 22.04/24.04 or Debian 12 recommended) with at least 4 GB RAM and 20 GB free disk
- Internet access during installation and updates
- Root access (`sudo`)

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/onlyg0843-alt/documenta/main/install.sh | sudo bash
```

The command installs Docker if it's missing, puts everything in `/opt/documenta`, generates this installation's secrets, downloads the application and starts it. The first run takes a few minutes, mostly for the document server download. At the end it prints the address and the first login: `docuadmin` / `changeme12345` (`superadmin` on older installations), which you must change on first sign-in. The login is printed only until that password has been changed, so later updates don't show it.

Then, signed in as the super admin, open the settings pages to set up ONLYOFFICE and upload your license, and optionally the Telegram page to connect your team's groups.

Options go in front of the command:

| Variable | Default | Meaning |
|---|---|---|
| `DOCUMENTA_PORT` | `80`, or `5075` if 80 is already taken | web port; kept on later runs |
| `DOCUMENTA_DIR` | `/opt/documenta` | install folder |
| `DOCUMENTA_VERSION` | `latest` | application version to run, e.g. `1.0.4`; kept on later runs |

Example with another port:

```bash
DOCUMENTA_PORT=8080 bash <(curl -fsSL https://raw.githubusercontent.com/onlyg0843-alt/documenta/main/install.sh)
```

## Update

```bash
documenta update
```

Downloads the newest version and restarts. Your data, settings and secrets are kept, and users stay signed in. A restart interrupts anyone who has a file open in the editor, so the command first checks for open editors and refuses if there are any; wait until it's quiet, or run `documenta update --force`.

Other commands:

| Command | Does |
|---|---|
| `documenta status` | shows the running services |
| `documenta logs [service]` | follows the logs (`api`, `frontend`, `onlyoffice`, `telegram-bot`, `mongodb`, `redis`) |
| `documenta restart [service]` | restarts everything or one service |
| `documenta stop` / `documenta start` | stops / starts everything |
| `documenta version` | shows the running version, its release date and the components' versions, and checks whether a newer release exists |
| `documenta help` | lists every command with what it does |

To stay on one version, or go back to it: `DOCUMENTA_VERSION=1.0.5 documenta update`. To follow new releases again: `DOCUMENTA_VERSION=latest documenta update`.

**Installed earlier from the archive (`Documenta-Deployment.tar.gz`)?** Run the installer with `DOCUMENTA_DIR` pointing at that folder, for example `DOCUMENTA_DIR=/root/documenta bash <(curl -fsSL https://raw.githubusercontent.com/onlyg0843-alt/documenta/main/install.sh)`. Your `.env` and data are kept. From then on use `documenta update`.

## Where things are

| Path | Contents |
|---|---|
| `/opt/documenta/.env` | ports, database name, this installation's secrets |
| `/opt/documenta/doc_data/db` | database |
| `/opt/documenta/doc_data/redis` | sign-in sessions |
| `/opt/documenta/doc_data/backend` | uploaded files, license, activity logs |

**Backup:** turn on Backups on the Features page: they go to a second disk mounted at `/srv/documenta-backups` (or `BACKUP_DISK` in `.env`) and/or a network share, on a schedule, and the Backups page shows how to set up the disk and restore. By hand: copy `/opt/documenta/doc_data` and `/opt/documenta/.env` together; to restore on a new server, put them back in place and run the installer.

**Uninstall:** `sudo documenta uninstall` removes Documenta and all its data from the server: the database and every file, the containers and their images (ONLYOFFICE included), `.env`, `/opt/documenta` and the `documenta` command. It shows all that first and goes on only when you type `DELETE EVERYTHING`. Backups on the backup disk are kept unless you answer YES to deleting them as well; Docker and backups on a network share are never touched. `--purge` removes without asking and keeps the backups.
