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
#   DOCUMENTA_VERSION  image tag to run          default latest (e.g. 1.2.0)
#   DOCUMENTA_PORT     web port                  default 80
#   DOCUMENTA_REF      git ref to fetch files from, default main (use the tag for a pinned version)
set -euo pipefail

REPO="onlyg0843-alt/documenta"
DOCUMENTA_DIR="${DOCUMENTA_DIR:-/opt/documenta}"
DOCUMENTA_VERSION="${DOCUMENTA_VERSION:-latest}"
DOCUMENTA_PORT="${DOCUMENTA_PORT:-80}"
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
if ! command -v docker >/dev/null 2>&1; then
    say "Installing Docker"
    curl -fsSL https://get.docker.com | sh
fi
docker compose version >/dev/null 2>&1 || fail "Docker Compose v2 is missing. Install the docker-compose-plugin package and run again."
systemctl enable --now docker >/dev/null 2>&1 || true

# ----- files -----
mkdir -p "$DOCUMENTA_DIR/doc_data/db" "$DOCUMENTA_DIR/doc_data/redis" "$DOCUMENTA_DIR/doc_data/backend"
cd "$DOCUMENTA_DIR"
FRESH_INSTALL=0
[ -n "$(ls -A doc_data/db 2>/dev/null)" ] || FRESH_INSTALL=1

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

set_default PORT 3000
set_default DB_NAME doc_db
set_default REDIS_PORT 6379
set_default DOCUMENTA_VERSION "$DOCUMENTA_VERSION"
set_default DOCUMENTA_PORT "$DOCUMENTA_PORT"
for key in ACCESS_TOKEN_SECRET REFRESH_TOKEN_SECRET ONLYOFFICE_JWT_SECRET TELEGRAM_INTERNAL_SECRET; do
    set_default "$key" "$(new_secret)"
done
# A requested version or port wins over what an earlier run wrote
sed -i "s|^DOCUMENTA_VERSION=.*|DOCUMENTA_VERSION=${DOCUMENTA_VERSION}|; s|^DOCUMENTA_PORT=.*|DOCUMENTA_PORT=${DOCUMENTA_PORT}|" .env

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
if [ "$DOCUMENTA_VERSION" = "latest" ]; then
    say "Pulling the latest images (this takes a few minutes the first time)"
else
    say "Pulling images for version ${DOCUMENTA_VERSION}"
fi
docker compose pull
say "Starting"
docker compose up -d --remove-orphans
docker image prune -f >/dev/null 2>&1 || true

IP="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"
URL="http://${IP:-<server-ip>}"
[ "$DOCUMENTA_PORT" != "80" ] && URL="${URL}:${DOCUMENTA_PORT}"
echo
say "Documenta is running at ${URL}"
if [ "$FRESH_INSTALL" = "1" ]; then
    echo "    First login:  superadmin / changeme12345  (you will be asked to change it)"
fi
echo "    Files:        ${DOCUMENTA_DIR}  (data in doc_data/, settings in .env)"
echo "    Commands:     documenta update | status | logs | restart | stop | start"
echo "                  (update refuses while files are open in the editor; add --force to override)"
