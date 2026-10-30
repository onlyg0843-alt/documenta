#!/bin/bash
# Installs or updates Documenta on a Linux server with one command:
#
#   curl -fsSL https://raw.githubusercontent.com/onlyg0843-alt/documenta/main/install.sh | sudo bash
#
# This file and docker-compose.yml live in the public repo github.com/onlyg0843-alt/documenta; the
# application code is in the private repo only-doc-main, whose release workflow builds the images.
#
# What it does: installs Docker if missing, puts docker-compose.yml and a .env with freshly generated
# secrets in /opt/documenta, pulls the images from GitHub Container Registry and starts everything.
# Run it again (or `documenta update`) to update: the existing .env, secrets and data are kept.
#
# Options, as environment variables:
#   DOCUMENTA_DIR      install folder            default /opt/documenta
#   DOCUMENTA_VERSION  image tag to run          default latest (e.g. 1.2.0); kept on re-runs
#   DOCUMENTA_PORT     web port                  default 80, or 5075 when 80 is taken; kept on re-runs
#   DOCUMENTA_REF      git ref to fetch files from, default main (use the tag for a pinned version)
set -euo pipefail

REPO="onlyg0843-alt/documenta"
DOCUMENTA_DIR="${DOCUMENTA_DIR:-/opt/documenta}"
DOCUMENTA_VERSION="${DOCUMENTA_VERSION:-}"   # empty = not requested: keep the installed one, else latest
DOCUMENTA_PORT="${DOCUMENTA_PORT:-}"         # empty = not requested: keep the installed one, else 80 / 5075
DOCUMENTA_REF="${DOCUMENTA_REF:-main}"
RAW="https://raw.githubusercontent.com/${REPO}/${DOCUMENTA_REF}"

say()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31mError:\033[0m %s\n' "$*" >&2; exit 1; }

# ----- root -----
if [ "$(id -u)" -ne 0 ]; then
    command -v sudo >/dev/null 2>&1 || fail "Run this as root (sudo is not installed)."
    say "Re-running with sudo"
    SELF="${BASH_SOURCE[0]:-}"
    if [ -z "$SELF" ] || [ ! -f "$SELF" ]; then   # piped from curl: fetch a copy to run
        SELF="$(mktemp)"
        curl -fsSL "${RAW}/install.sh" -o "$SELF"
    fi
    exec sudo DOCUMENTA_DIR="$DOCUMENTA_DIR" DOCUMENTA_VERSION="$DOCUMENTA_VERSION" \
        DOCUMENTA_PORT="$DOCUMENTA_PORT" DOCUMENTA_REF="$DOCUMENTA_REF" bash "$SELF"
fi

command -v curl >/dev/null 2>&1 || fail "curl is required. Install it (e.g. apt install curl) and run again."

# ----- Docker -----
# "Usable" means the Linux Docker with the Compose plugin. Inside WSL a Windows docker.exe can appear on
# the PATH through interop (under /mnt/c/...); that one must not count.
docker_usable() {
    local bin
    bin="$(command -v docker 2>/dev/null)" || return 1
    case "$bin" in /mnt/*) return 1 ;; esac
    docker compose version >/dev/null 2>&1
}
if ! docker_usable; then
    say "Installing Docker"
    curl -fsSL https://get.docker.com | sh
fi
docker_usable || fail "Docker is installed but 'docker compose' does not work. Install the docker-compose-plugin package and run again."
systemctl enable --now docker >/dev/null 2>&1 || true

# ----- files -----
mkdir -p "$DOCUMENTA_DIR/doc_data/db" "$DOCUMENTA_DIR/doc_data/redis" "$DOCUMENTA_DIR/doc_data/backend"
cd "$DOCUMENTA_DIR"

say "Fetching docker-compose.yml (${DOCUMENTA_REF})"
curl -fsSL "${RAW}/docker-compose.yml" -o docker-compose.yml.new
mv docker-compose.yml.new docker-compose.yml

# ----- .env: keep what exists, add what is missing, generate every secret per installation -----
touch .env
chmod 600 .env
set_default() {  # set_default KEY VALUE — only when KEY is not in .env yet
    grep -q "^$1=" .env || printf '%s=%s\n' "$1" "$2" >> .env
}
new_secret() { head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n'; }

# Something listening on the port (checked only before the first install: afterwards it's our own container)
port_busy() {
    if command -v ss >/dev/null 2>&1; then ss -ltn 2>/dev/null | awk '{print $4}' | grep -qE "[:.]$1\$"
    else (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null; fi
}
installed_port="$(grep '^DOCUMENTA_PORT=' .env | cut -d= -f2- || true)"
if [ -n "$DOCUMENTA_PORT" ]; then
    PORT="$DOCUMENTA_PORT"
    if [ -z "$installed_port" ] && port_busy "$PORT"; then
        fail "Port $PORT is already in use. Choose another one with DOCUMENTA_PORT=<port>."
    fi
elif [ -n "$installed_port" ]; then
    PORT="$installed_port"
else
    PORT=80
    if port_busy 80; then
        PORT=5075
        say "Port 80 is in use by another program; using port 5075 instead"
        if port_busy 5075; then fail "Ports 80 and 5075 are both in use. Choose another one with DOCUMENTA_PORT=<port>."; fi
    fi
fi

set_default PORT 3000
set_default DB_NAME doc_db
set_default REDIS_PORT 6379
set_default DOCUMENTA_VERSION "${DOCUMENTA_VERSION:-latest}"
set_default DOCUMENTA_PORT "$PORT"
for key in ACCESS_TOKEN_SECRET REFRESH_TOKEN_SECRET ONLYOFFICE_JWT_SECRET TELEGRAM_INTERNAL_SECRET; do
    set_default "$key" "$(new_secret)"
done
# An explicitly requested version or port wins over what an earlier run wrote; otherwise those are kept
if [ -n "$DOCUMENTA_VERSION" ]; then sed -i "s|^DOCUMENTA_VERSION=.*|DOCUMENTA_VERSION=${DOCUMENTA_VERSION}|" .env; fi
if [ -n "$DOCUMENTA_PORT" ]; then sed -i "s|^DOCUMENTA_PORT=.*|DOCUMENTA_PORT=${PORT}|" .env; fi
VERSION="$(grep '^DOCUMENTA_VERSION=' .env | cut -d= -f2-)"

chmod -R 777 doc_data   # the containers run as different users

# ----- the `documenta` command -----
# Written with a quoted heredoc (no expansion here); __DIR__, __REF__ and __RAW__ are filled in below.
cat > /usr/local/bin/documenta <<'EOF'
#!/bin/bash
# Manage the Documenta installation in __DIR__
set -e
cd "__DIR__"
envval() { grep "^$1=" .env | cut -d= -f2-; }

# How many files are open in the editor right now: documents being edited, templates and records
# locked by ONLYOFFICE. Updating restarts containers, which would interrupt them.
open_editors() {
    docker compose exec -T mongodb mongosh --quiet "$(envval DB_NAME)" --eval \
        'print(db.collaborationdocuments.countDocuments({isEditing:true}) + db.templates.countDocuments({isLocked:true}) + db.records.countDocuments({isLocked:true}))' \
        2>/dev/null | tr -d '[:space:]'
}

case "${1:-}" in
    update)
        if [ "${2:-}" != "--force" ]; then
            open="$(open_editors || true)"
            if [ -n "$open" ] && [ "$open" != "0" ]; then
                echo "$open file(s) are open in the editor. Updating now would interrupt them."
                echo "Wait until nobody is editing, or run: documenta update --force"
                exit 1
            fi
        fi
        DOCUMENTA_DIR="__DIR__" DOCUMENTA_REF="${DOCUMENTA_REF:-__REF__}" \
        DOCUMENTA_VERSION="${DOCUMENTA_VERSION:-$(envval DOCUMENTA_VERSION)}" \
        DOCUMENTA_PORT="$(envval DOCUMENTA_PORT)" \
        bash -c "$(curl -fsSL __RAW__/install.sh)" ;;
    status)  docker compose ps ;;
    logs)    docker compose logs -f --tail 100 "${@:2}" ;;
    restart) docker compose restart "${@:2}" ;;
    stop)    docker compose down ;;
    start)   docker compose up -d ;;
    *)       echo "Usage: documenta update [--force]|status|logs [service]|restart [service]|stop|start"; exit 1 ;;
esac
EOF
sed -i "s|__DIR__|${DOCUMENTA_DIR}|g; s|__REF__|${DOCUMENTA_REF}|g; s|__RAW__|${RAW}|g" /usr/local/bin/documenta
chmod +x /usr/local/bin/documenta

# ----- run -----
if [ "$VERSION" = "latest" ]; then
    say "Pulling the latest images (this takes a few minutes the first time)"
else
    say "Pulling images for version ${VERSION}"
fi
docker compose pull
say "Starting"
docker compose up -d --remove-orphans
docker image prune -f >/dev/null 2>&1 || true

# ----- wait until the app answers: the API needs a moment after the containers start -----
printf '==> Waiting for Documenta to answer'
UP=0
for i in $(seq 1 60); do
    code="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${PORT}/api/auth/profile" 2>/dev/null || true)"
    case "$code" in 200|401) UP=1; break ;; esac
    printf '.'; sleep 3
done
echo

IP="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"
URL="http://${IP:-<server-ip>}"
[ "$PORT" != "80" ] && URL="${URL}:${PORT}"
echo
if [ "$UP" = "1" ]; then
    say "Documenta is running at ${URL}"
else
    say "Documenta is starting at ${URL} but does not answer yet; check in a minute with: documenta status, documenta logs api"
fi
echo "    Login:        superadmin / changeme12345  (on a new installation; you will be asked to change it at first sign-in)"
echo "    Files:        ${DOCUMENTA_DIR}  (data in doc_data/, settings in .env)"
echo "    Commands:     documenta update | status | logs | restart | stop | start"
echo "                  (update refuses while files are open in the editor; add --force to override)"
