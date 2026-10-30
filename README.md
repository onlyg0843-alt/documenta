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

The command installs Docker if it's missing, puts everything in `/opt/documenta`, generates this installation's secrets, downloads the application and starts it. The first run takes a few minutes, mostly for the document server download. At the end it prints the address and the first login: `superadmin` / `changeme12345`, which you must change on first sign-in.

Then, signed in as superadmin, open the settings pages to set up ONLYOFFICE and upload your license, and optionally the Telegram page to connect your team's groups.

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

## Install on Windows Server

Documenta runs as Linux containers, so on Windows it lives inside WSL 2 (built into Windows Server 2022 and Windows 10/11; the server needs virtualization enabled, which for a VM means nested virtualization). Two ways to start:

- **Setup program:** download `Documenta-Setup.msi` from the [latest release](https://github.com/onlyg0843-alt/documenta/releases/latest), run it and keep "Run the Documenta installer now" ticked. Later, "Install or update Documenta" in the Start Menu runs the same installer.
- **One command**, in a PowerShell window started as Administrator:

  ```powershell
  irm https://raw.githubusercontent.com/onlyg0843-alt/documenta/main/install.ps1 | iex
  ```

The installer enables WSL 2 (one reboot the first time, then run it again), creates a Linux environment named `documenta` under `C:\Program Files\Documenta`, installs Docker inside it and then does exactly what the Linux install does. It forwards the chosen port from Windows to the app and registers a startup task; it asks for your Windows password once so the app can start after a reboot without anyone signing in (press Enter to skip, then it starts when you sign in). Options are the same as on Linux, set as `$env:DOCUMENTA_PORT = '8080'` before the command. If port 80 is already taken (IIS, for example) and you didn't choose a port, it uses 5075 and says so. If the server has several network adapters, the installer lists them right at the start and waits 20 seconds for you to pick the one people will use; otherwise it takes the first physical one. The app is reachable on every address of the server either way; the choice only decides which address is shown.

For developers: the setup program's logo images (`windows/msi/banner.bmp`, `dialog.bmp`, `documenta.ico`) are rendered from the app's `frontend/public/documenta_icon.svg` (SVG → 512 px PNG with `sharp`, then drawn onto white with System.Drawing); regenerate them if the logo changes.

Afterwards `documenta update`, `status`, `logs` and the others work from any new PowerShell or Command Prompt window, plus two Windows-only ones: `documenta backup [file]` exports the whole system including data to a `.tar` (in your Documents folder unless you name a file), and `documenta uninstall` removes everything.

**Uninstalling on Windows:** "Documenta" in Apps & features (the setup program) stops Documenta and removes the program parts but keeps the data, in the WSL distro `documenta` under `C:\Program Files\Documenta\wsl`; it tells you so. `documenta uninstall` (in a window started as Administrator) removes the data as well; if you used the setup program, remove "Documenta" from Apps & features afterwards too.

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

**Installed earlier from the archive (`Documenta-Deployment.tar.gz`)?** Run the installer with `DOCUMENTA_DIR` pointing at that folder, for example `DOCUMENTA_DIR=/root/documenta bash <(curl -fsSL https://raw.githubusercontent.com/onlyg0843-alt/documenta/main/install.sh)`. Your `.env` and data are kept. From then on use `documenta update`.

## Where things are

| Path | Contents |
|---|---|
| `/opt/documenta/.env` | ports, database name, this installation's secrets |
| `/opt/documenta/doc_data/db` | database |
| `/opt/documenta/doc_data/redis` | sign-in sessions |
| `/opt/documenta/doc_data/backend` | uploaded files, license, activity logs |

**Backup:** copy `/opt/documenta/doc_data` and `/opt/documenta/.env` together. To restore on a new server, put them back in place and run the installer.

**Uninstall:** `documenta stop`, then delete `/opt/documenta` and `/usr/local/bin/documenta`.
