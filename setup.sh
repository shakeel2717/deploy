#!/bin/bash
###############################################################################
#  Laravel Multi-Site Setup Wizard  —  idempotent / safe to re-run
#  Ubuntu 22.04 / 24.04  •  Laravel 12  •  Octane + Horizon + Reverb + Scheduler
#
#  Usage:
#    ./deploy.sh                 install new site(s) / redeploy existing ones
#    ./deploy.sh --list          show every site on this server and its status
#    ./deploy.sh --remove SLUG   completely remove one site (backs up first)
#    ./deploy.sh --repair        backfill registry + missing REDIS_QUEUE_DB
#    ./deploy.sh --help
#
#  Run again any time to ADD a new site. Existing sites are never touched.
###############################################################################
set -euo pipefail

APP_USER="larasail"
WEB_ROOT="/var/www"
STATE_DIR="/etc/laravel-multisite"
SITES_DIR="$STATE_DIR/sites"
PROVISION_MARKER="$STATE_DIR/.provisioned"
CRED_FILE="/root/laravel-sites-credentials.txt"
BACKUP_DIR="/root/removed-sites"
LOCK_FILE="$STATE_DIR/.lock"
SUP_DIR="/etc/supervisor/conf.d"

DEFAULT_SSL_CERT="/etc/ssl/certs/cloudflare-origin.pem"
DEFAULT_SSL_KEY="/etc/ssl/private/cloudflare-origin.key"

# Redis DBs consumed per site: default (sessions), cache, queue.
REDIS_DBS_PER_SITE=3

# --help needs neither root nor any state on disk.
case "${1:-}" in --help|-h) sed -n '2,14p' "$0" | sed 's/^#[[:space:]]\?//'; exit 0 ;; esac

[ "$EUID" -eq 0 ] || { echo "ERROR: run as root (sudo -i)"; exit 1; }
mkdir -p "$SITES_DIR"

# Report where we died instead of exiting silently on the failing line.
trap 'rc=$?; echo ""; echo "!! ABORTED at line $LINENO (exit $rc)." >&2' ERR

###############################################################################
#  Only one copy of this script may run at a time.
#
#  Port and Redis-DB allocation works by snapshotting what is currently in use.
#  Two concurrent runs both snapshot the same state and both hand out port 8000
#  and Redis DB 0, so the second site to boot silently fails. The lock is what
#  makes "install two sites at once" safe: the second run waits its turn and
#  then sees the first run's allocations.
###############################################################################
if command -v flock >/dev/null 2>&1; then
    exec 9>"$LOCK_FILE"
    if ! flock -n 9; then
        echo "Another deploy.sh is already running (lock: $LOCK_FILE)."
        echo "Waiting for it to finish..."
        flock 9
    fi
else
    # util-linux ships flock on every Ubuntu, so this should not happen. Warn
    # rather than refuse: losing the lock is worse than nothing only if two
    # runs actually overlap.
    echo "WARNING: 'flock' not found — concurrent runs of this script are NOT"
    echo "         protected. Do not start a second one until this finishes."
fi

###############################################################################
#  Helpers
###############################################################################

die()  { echo ""; echo "ERROR: $*" >&2; exit 1; }
note() { echo "  $*"; }

# env_set KEY VALUE FILE  — updates the key, or appends it if missing.
# The value is escaped for sed: & means "the whole match" and | is our delimiter.
env_set() {
    local k="$1" v="$2" f="$3" esc
    esc=$(printf '%s' "$v" | sed -e 's/[&|\\]/\\&/g')
    if grep -q "^${k}=" "$f"; then
        sed -i "s|^${k}=.*|${k}=${esc}|" "$f"
    else
        printf '%s=%s\n' "$k" "$v" >> "$f"
    fi
}

env_get() { grep "^${1}=" "$2" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '\r"' || true; }

rand() { tr -dc "$1" < /dev/urandom | head -c "$2"; echo; }

as_app()  { sudo -u "$APP_USER" -H env HOME="/home/$APP_USER" "$@"; }
as_web()  { sudo -u www-data   -H env HOME="/var/www" "$@"; }

# Is this package already a dependency? Re-requiring it rewrites composer.lock,
# which turns the next `git pull` on the server into a merge conflict.
composer_has() {
    grep -qE "\"$1\"[[:space:]]*:" "$2/composer.json" 2>/dev/null
}

# alloc_port START -> sets $ALLOC_PORT (skips anything already used/listening)
alloc_port() {
    local p="$1"
    while [[ " $PORTS_IN_USE " == *" $p "* ]]; do p=$((p + 1)); done
    PORTS_IN_USE="$PORTS_IN_USE $p"
    ALLOC_PORT="$p"
}

# alloc_redis -> sets $ALLOC_REDIS (first free redis DB index)
alloc_redis() {
    local d=0
    while [[ " $REDIS_IN_USE " == *" $d "* ]]; do d=$((d + 1)); done
    [ "$d" -ge "$REDIS_MAX_DB" ] && die "Out of Redis databases (limit $REDIS_MAX_DB). Raise 'databases' in /etc/redis/redis.conf and restart redis."
    REDIS_IN_USE="$REDIS_IN_USE $d"
    ALLOC_REDIS="$d"
}

# Number of databases this redis instance actually offers.
redis_max_db() {
    local n
    n=$(redis-cli CONFIG GET databases 2>/dev/null | tail -1 || true)
    if [[ "$n" =~ ^[0-9]+$ ]]; then echo "$n"; else echo 16; fi
}

# nginx >= 1.25.1 uses `http2 on;`. Older releases (Ubuntu 24.04 ships 1.24)
# only understand `listen ... http2`, and reject the new form outright — which
# would take down every site on the box at the next reload.
nginx_http2_directive() {
    local v
    v=$(nginx -v 2>&1 | sed -n 's|.*nginx/\([0-9.]*\).*|\1|p')
    if [ -n "$v" ] && [ "$(printf '%s\n1.25.1\n' "$v" | sort -V | head -1)" = "1.25.1" ]; then
        echo "modern"
    else
        echo "legacy"
    fi
}

# Reload nginx, but never leave a broken config behind.
nginx_apply() {
    if ! nginx -t; then
        die "nginx config test FAILED (see above). Nothing was reloaded; live sites are still serving the previous config."
    fi
    systemctl reload nginx
}

# Every supervisor program belonging to one site.
site_programs() {
    supervisorctl status 2>/dev/null | awk '{print $1}' | grep -E "_${1}\$" || true
}

registry_file() { echo "${SITES_DIR}/${1}.conf"; }

# Every "PORT SLUG" pair claimed by a supervisor program or a registry entry.
# Supervisor programs are named <service>_<slug>.conf, so the slug is whatever
# follows the first underscore.
#
# Always succeeds: under `set -euo pipefail` a file with no port in it (horizon,
# scheduler) would otherwise fail the pipeline and abort the whole script.
port_claims() {
    local f s
    for f in "$SUP_DIR"/*.conf; do
        [ -f "$f" ] || continue
        s=$(basename "$f" .conf); s="${s#*_}"
        { grep -ho -- '--port=[0-9]*' "$f" 2>/dev/null || true; } | cut -d= -f2 | sed "s/\$/ ${s}/"
    done
    for f in "$SITES_DIR"/*.conf; do
        [ -f "$f" ] || continue
        s=$(basename "$f" .conf)
        { grep -h -E '^(OCTANE_PORT|REVERB_PORT)=[0-9]+' "$f" 2>/dev/null || true; } | cut -d= -f2 | sed "s/\$/ ${s}/"
    done
    return 0
}

# port_owner PORT SLUG -> prints the OTHER site already claiming PORT, if any.
# awk reads to the end rather than exiting on the first match: an early exit
# breaks the pipe under port_claims, which pipefail turns into a failure.
port_owner() {
    port_claims | awk -v p="$1" -v me="$2" '$1 == p && $2 != me && found == "" { found = $2 } END { if (found != "") print found }'
}

# "PORT: siteA siteB" for every port more than one site claims. Two sites on
# one port means one of them cannot start — and nginx for the other may be
# proxying its domain straight into the wrong site.
port_clashes() {
    port_claims | sort -u | awk '{ s[$1] = s[$1] " " $2; n[$1]++ } END { for (p in s) if (n[p] > 1) print p ":" s[p] }' | sort -n
}

# What is wrong with an existing site's isolation, one line per problem.
# Without its own Redis databases and prefixes a site shares cache, queues and
# Horizon with whichever site has the defaults; with the file cache the
# per-number booking lock and the remaining cache switch themselves off.
env_isolation_problems() {
    local envf="$1" k
    for k in REDIS_DB REDIS_CACHE_DB REDIS_PREFIX CACHE_PREFIX HORIZON_PREFIX; do
        [ -n "$(env_get "$k" "$envf")" ] || echo "no $k — shares Redis with other sites"
    done
    [ -n "$(env_get REDIS_QUEUE_DB "$envf")" ] || echo "no REDIS_QUEUE_DB — queues share redis db 3 (fix: $0 --repair)"
    [ "$(env_get CACHE_STORE "$envf")" = "redis" ] || echo "CACHE_STORE is '$(env_get CACHE_STORE "$envf")', not redis"
}

###############################################################################
#  Subcommand: --list
###############################################################################
cmd_list() {
    local any=0 slug progs
    echo "=============================================="
    echo "  Sites on this server"
    echo "=============================================="
    for f in "$SITES_DIR"/*.conf; do
        [ -f "$f" ] || continue
        any=1
        # shellcheck disable=SC1090
        ( set +u; . "$f"
          echo ""
          echo "  ${SLUG:-?}  ->  ${DOMAIN:-?}"
          echo "    Dir      : ${DIR:-?}"
          echo "    PHP      : ${PHP_VER:-?}   SSL: ${SSL_MODE:-?}"
          echo "    Octane   : ${OCTANE_PORT:-none}   Reverb: ${REVERB_PORT:-none}"
          echo "    Redis    : db ${REDIS_DB:-?} / cache ${REDIS_CACHE_DB:-?} / queue ${REDIS_QUEUE_DB:-UNSET}"
          echo "    Database : ${DB_NAME:-?} (${DB_USER:-?})"
          echo "    Created  : ${CREATED:-?}"
        )
        slug=$(basename "$f" .conf)
        progs=$(site_programs "$slug")
        if [ -n "$progs" ]; then
            echo "    Services :"
            supervisorctl status 2>/dev/null | grep -E "_${slug}[[:space:]]" | sed 's/^/      /' || true
        fi
    done
    [ "$any" = 0 ] && echo "  (none registered — run --repair if sites exist in $WEB_ROOT)"

    local clashes
    clashes=$(port_clashes)
    if [ -n "$clashes" ]; then
        echo ""
        echo "  !! PORT CLASH — more than one site claims the same port:"
        echo "$clashes" | sed 's/^/       /'
        echo "     Only one of them can run. Move the newer site to a free port."
    fi
    echo ""
}

###############################################################################
#  Subcommand: --remove SLUG
#
#  Deliberately backs everything up before destroying it. A removal that turns
#  out to have been the wrong slug is otherwise unrecoverable.
###############################################################################
cmd_remove() {
    local slug="$1" reg stamp progs p db
    reg=$(registry_file "$slug")

    local DOMAIN="" DIR="$WEB_ROOT/$slug" DB_NAME="" DB_USER=""
    local REDIS_DB="" REDIS_CACHE_DB="" REDIS_QUEUE_DB="" NGINX_CONF=""

    if [ -f "$reg" ]; then
        # shellcheck disable=SC1090
        set +u; . "$reg"; set -u
    else
        echo "No registry entry for '$slug'. Falling back to reading $DIR/.env"
        [ -f "$DIR/.env" ] || die "Neither $reg nor $DIR/.env exists. Nothing to remove."
        DOMAIN=$(env_get APP_URL "$DIR/.env" | sed 's|https\?://||')
        DB_NAME=$(env_get DB_DATABASE "$DIR/.env")
        DB_USER=$(env_get DB_USERNAME "$DIR/.env")
        REDIS_DB=$(env_get REDIS_DB "$DIR/.env")
        REDIS_CACHE_DB=$(env_get REDIS_CACHE_DB "$DIR/.env")
        REDIS_QUEUE_DB=$(env_get REDIS_QUEUE_DB "$DIR/.env")
    fi

    echo "=============================================="
    echo "  REMOVE SITE: $slug"
    echo "=============================================="
    echo "  Domain    : ${DOMAIN:-unknown}"
    echo "  Directory : ${DIR:-unknown}          (will be DELETED)"
    echo "  Database  : ${DB_NAME:-none}         (will be DROPPED)"
    echo "  DB user   : ${DB_USER:-none}         (will be DROPPED)"
    echo "  Redis DBs : ${REDIS_DB:-?} ${REDIS_CACHE_DB:-?} ${REDIS_QUEUE_DB:-?}  (will be FLUSHED)"
    echo "  Services  : $(site_programs "$slug" | tr '\n' ' ')"
    echo ""
    echo "  A database dump and a copy of .env + storage/app go to $BACKUP_DIR first."
    echo ""
    read -rp "  Type the slug '$slug' to confirm: " CONFIRM
    [ "$CONFIRM" = "$slug" ] || die "Confirmation did not match. Nothing removed."

    mkdir -p "$BACKUP_DIR"; chmod 700 "$BACKUP_DIR"
    stamp=$(date +%Y%m%d-%H%M%S)

    # ---- 1. Back up ------------------------------------------------------
    if [ -n "$DB_NAME" ] && mysql -e "USE \`$DB_NAME\`" 2>/dev/null; then
        echo "==> Dumping database $DB_NAME"
        mysqldump --single-transaction --routines --triggers "$DB_NAME" \
            | gzip > "${BACKUP_DIR}/${slug}-${stamp}.sql.gz"
    fi
    if [ -d "$DIR" ]; then
        echo "==> Archiving .env and storage/app"
        tar -czf "${BACKUP_DIR}/${slug}-${stamp}-files.tar.gz" \
            -C "$DIR" .env storage/app 2>/dev/null || true
    fi
    chmod 600 "$BACKUP_DIR"/*"$slug"* 2>/dev/null || true

    # ---- 2. Stop and remove services ------------------------------------
    echo "==> Stopping services"
    progs=$(site_programs "$slug")
    for p in $progs; do supervisorctl stop "$p" >/dev/null 2>&1 || true; done
    rm -f /etc/supervisor/conf.d/*_"${slug}".conf
    supervisorctl reread >/dev/null 2>&1 || true
    supervisorctl update >/dev/null 2>&1 || true

    # ---- 3. Nginx --------------------------------------------------------
    echo "==> Removing nginx config"
    rm -f /etc/nginx/sites-enabled/"${slug}"_*.conf /etc/nginx/sites-available/"${slug}"_*.conf
    if [ -n "${NGINX_CONF:-}" ]; then
        rm -f "$NGINX_CONF" "/etc/nginx/sites-enabled/$(basename "$NGINX_CONF")"
    fi
    nginx_apply

    # ---- 4. MySQL --------------------------------------------------------
    # Dropping the user removes every grant it held, including the cross-site
    # grants issued in step [4/6] of an install.
    if [ -n "$DB_NAME" ]; then
        echo "==> Dropping database $DB_NAME"
        mysql -e "DROP DATABASE IF EXISTS \`${DB_NAME}\`;"
    fi
    if [ -n "$DB_USER" ]; then
        echo "==> Dropping user $DB_USER"
        mysql -e "DROP USER IF EXISTS '${DB_USER}'@'localhost';"
        mysql -e "FLUSH PRIVILEGES;"
    fi

    # ---- 5. Redis --------------------------------------------------------
    for db in "${REDIS_DB:-}" "${REDIS_CACHE_DB:-}" "${REDIS_QUEUE_DB:-}"; do
        [[ "$db" =~ ^[0-9]+$ ]] || continue
        echo "==> Flushing redis db $db"
        redis-cli -n "$db" FLUSHDB >/dev/null 2>&1 || true
    done

    # ---- 6. Files, git config, registry ---------------------------------
    if [ -d "$DIR" ]; then
        echo "==> Deleting $DIR"
        rm -rf "${DIR:?}"
    fi
    git config --system --unset-all safe.directory "$DIR" 2>/dev/null || true
    git config --global --unset-all safe.directory "$DIR" 2>/dev/null || true
    rm -f "$reg"

    {
        echo ""
        echo "===== REMOVED $(date) ====="
        echo "Site   : $slug (${DOMAIN:-unknown})"
        echo "Backup : ${BACKUP_DIR}/${slug}-${stamp}.*"
    } >> "$CRED_FILE"

    echo ""
    echo "=============================================="
    echo "  '$slug' removed."
    echo "  Backups: ${BACKUP_DIR}/${slug}-${stamp}.*"
    echo "  Remember to delete the DNS record in Cloudflare."
    echo "=============================================="
}

###############################################################################
#  Subcommand: --repair
#
#  Two jobs, both aimed at servers built by the older version of this script:
#    1. Sites with no registry file get one, reconstructed from disk.
#    2. Sites with no REDIS_QUEUE_DB get one.
#
#  (2) matters. config/database.php falls back to env('REDIS_QUEUE_DB', 3), so
#  every site without it queues into Redis db 3 — while some *other* site has
#  db 3 as its cache. Laravel's redis cache flush is a FLUSHDB, so that site
#  running `cache:clear` (which `optimize:clear`, and therefore every deploy,
#  calls) erases all the other sites' pending jobs.
###############################################################################
cmd_repair() {
    local changed=0 d slug reg envf dom op rp entry s db

    echo "=============================================="
    echo "  Repair"
    echo "=============================================="

    REDIS_MAX_DB=$(redis_max_db)
    REDIS_IN_USE="$(grep -h -E '^(REDIS_DB|REDIS_CACHE_DB|REDIS_QUEUE_DB)=' "$WEB_ROOT"/*/.env 2>/dev/null \
        | cut -d= -f2 | tr -d '\r' | tr '\n' ' ' || true)"

    for d in "$WEB_ROOT"/*/; do
        [ -f "${d}artisan" ] || continue
        [ -f "${d}.env" ]    || continue
        slug=$(basename "$d")
        reg=$(registry_file "$slug")
        envf="${d}.env"

        echo ""
        echo ">>> $slug"

        # --- registry backfill -------------------------------------------
        if [ ! -f "$reg" ]; then
            note "no registry entry — reconstructing from disk"
            dom=$(env_get APP_URL "$envf" | sed 's|https\?://||')
            op=$(grep -ho -- '--port=[0-9]*' "/etc/supervisor/conf.d/octane_${slug}.conf" 2>/dev/null | cut -d= -f2 || true)
            rp=$(grep -ho -- '--port=[0-9]*' "/etc/supervisor/conf.d/reverb_${slug}.conf" 2>/dev/null | cut -d= -f2 || true)
            cat > "$reg" << REGEOF
SLUG=${slug}
DOMAIN=${dom}
DIR=${d%/}
PHP_VER=$(ls /etc/php 2>/dev/null | sort -V | tail -1)
OCTANE_PORT=${op}
REVERB_PORT=${rp}
REDIS_DB=$(env_get REDIS_DB "$envf")
REDIS_CACHE_DB=$(env_get REDIS_CACHE_DB "$envf")
REDIS_QUEUE_DB=$(env_get REDIS_QUEUE_DB "$envf")
DB_NAME=$(env_get DB_DATABASE "$envf")
DB_USER=$(env_get DB_USERNAME "$envf")
SSL_MODE=unknown
NGINX_CONF=$(ls /etc/nginx/sites-available/"${slug}"_*.conf 2>/dev/null | head -1)
CREATED="reconstructed $(date +%F)"
REGEOF
            chmod 600 "$reg"
            changed=1
        fi

        # --- REDIS_QUEUE_DB ----------------------------------------------
        if [ -z "$(env_get REDIS_QUEUE_DB "$envf")" ]; then
            alloc_redis
            note "REDIS_QUEUE_DB missing -> assigning db $ALLOC_REDIS"
            note "  (was silently sharing db 3 with every other site)"
            REPAIR_QUEUE_SITES+=("$slug:$ALLOC_REDIS:$envf:$reg")
            changed=1
        else
            note "REDIS_QUEUE_DB=$(env_get REDIS_QUEUE_DB "$envf") — ok"
        fi
    done

    if [ "${#REPAIR_QUEUE_SITES[@]}" -gt 0 ]; then
        echo ""
        echo "  ------------------------------------------------------------"
        echo "  READ THIS BEFORE CONFIRMING"
        echo "  ------------------------------------------------------------"
        echo "  Moving a site's queue to a new Redis db orphans any jobs that"
        echo "  are currently waiting in the old one. Drain the queues first:"
        echo ""
        echo "    redis-cli -n 3 KEYS '*'         # should be empty"
        echo ""
        echo "  Do this on a quiet day, NOT during a draw."
        echo "  ------------------------------------------------------------"
        echo ""
        read -rp "  Apply REDIS_QUEUE_DB changes now? [y/N]: " V
        if [[ "${V:-n}" =~ ^[Yy]$ ]]; then
            for entry in "${REPAIR_QUEUE_SITES[@]}"; do
                IFS=: read -r s db envf reg <<< "$entry"
                env_set REDIS_QUEUE_DB "$db" "$envf"
                if [ -f "$reg" ]; then
                    if grep -q '^REDIS_QUEUE_DB=' "$reg"; then
                        sed -i "s|^REDIS_QUEUE_DB=.*|REDIS_QUEUE_DB=${db}|" "$reg"
                    else
                        echo "REDIS_QUEUE_DB=${db}" >> "$reg"
                    fi
                fi
                echo "  $s -> queue db $db"
                ( cd "$(dirname "$envf")" && as_web php artisan config:cache >/dev/null 2>&1 ) || true
                supervisorctl restart "horizon_${s}" >/dev/null 2>&1 || true
                supervisorctl restart "octane_${s}"  >/dev/null 2>&1 || true
            done
            echo ""
            echo "  Applied. Verify with: $0 --list"
        else
            echo "  Skipped. Re-run --repair when you are ready."
        fi
    fi

    [ "$changed" = 0 ] && { echo ""; echo "  Nothing to repair."; }
    echo ""
}

###############################################################################
#  Argument handling
###############################################################################
declare -a REPAIR_QUEUE_SITES=()

case "${1:-}" in
    --list)   cmd_list; exit 0 ;;
    --remove) [ -n "${2:-}" ] || die "Usage: $0 --remove SLUG"; cmd_remove "$2"; exit 0 ;;
    --repair) cmd_repair; exit 0 ;;
    --help|-h) sed -n '2,14p' "$0" | sed 's/^#[[:space:]]\?//'; exit 0 ;;
    "") ;;
    *) die "Unknown option '$1'. Try --help." ;;
esac

###############################################################################
#  Discover what is already on this server
###############################################################################
echo "=============================================="
echo "  Laravel Multi-Site Setup Wizard"
echo "=============================================="
echo ""

EXISTING_SITES=()
for d in "$WEB_ROOT"/*/; do
    [ -f "${d}artisan" ] && EXISTING_SITES+=("$(basename "$d")")
done

# Ports already claimed by the registry, by supervisor programs, or listening.
# The registry is included because a site whose services are stopped still owns
# its port — otherwise a new install would be handed a port that breaks the
# stopped site the moment it comes back up.
PORTS_IN_USE="$(grep -h -E '^(OCTANE_PORT|REVERB_PORT)=' "$SITES_DIR"/*.conf 2>/dev/null | cut -d= -f2 | tr '\n' ' ' || true)"
PORTS_IN_USE="$PORTS_IN_USE $(grep -rho -- '--port=[0-9]*' /etc/supervisor/conf.d/ 2>/dev/null | cut -d= -f2 | tr '\n' ' ' || true)"
PORTS_IN_USE="$PORTS_IN_USE $(ss -lntH 2>/dev/null | awk '{print $4}' | sed 's/.*://' | tr '\n' ' ' || true)"

# Redis DB indexes claimed by existing .env files or the registry. All three
# keys matter: default, cache AND queue.
REDIS_IN_USE="$(grep -h -E '^(REDIS_DB|REDIS_CACHE_DB|REDIS_QUEUE_DB)=' "$WEB_ROOT"/*/.env 2>/dev/null | cut -d= -f2 | tr -d '\r' | tr '\n' ' ' || true)"
REDIS_IN_USE="$REDIS_IN_USE $(grep -h -E '^(REDIS_DB|REDIS_CACHE_DB|REDIS_QUEUE_DB)=' "$SITES_DIR"/*.conf 2>/dev/null | cut -d= -f2 | tr '\n' ' ' || true)"
REDIS_MAX_DB=$(redis_max_db)

# Both lists are unions of several sources, so the same port / db index shows up
# more than once. Dedupe before anything counts them.
PORTS_IN_USE="$(echo "$PORTS_IN_USE" | tr ' ' '
' | grep -E '^[0-9]+$' | sort -un | tr '
' ' ')"
REDIS_IN_USE="$(echo "$REDIS_IN_USE" | tr ' ' '
' | grep -E '^[0-9]+$' | sort -un | tr '
' ' ')"

if [ ${#EXISTING_SITES[@]} -gt 0 ]; then
    echo "  Existing sites detected (${#EXISTING_SITES[@]}):"
    for s in "${EXISTING_SITES[@]}"; do
        SD=$(env_get APP_URL "$WEB_ROOT/$s/.env")
        echo "    - $s  ${SD}"
        if [ -f "$WEB_ROOT/$s/.env" ]; then
            while IFS= read -r problem; do
                [ -n "$problem" ] && echo "        WARNING: $problem"
            done < <(env_isolation_problems "$WEB_ROOT/$s/.env")
        fi
    done
    echo "  Ports in use     : ${PORTS_IN_USE:-none}"
    echo "  Redis DBs in use : ${REDIS_IN_USE:-none}  (of $REDIS_MAX_DB)"

    CLASHES=$(port_clashes)
    if [ -n "$CLASHES" ]; then
        echo ""
        echo "  !! PORT CLASH on this server — more than one site claims the same port:"
        echo "$CLASHES" | sed 's/^/       /'
        echo "     Only one of each can run; the other site's nginx may be serving the"
        echo "     wrong app. Fix this before installing anything new."
    fi
    echo ""
fi

###############################################################################
#  Questions
###############################################################################
while true; do
    read -rp "How many NEW sites to install? (1-5) [1]: " SITE_COUNT
    SITE_COUNT=${SITE_COUNT:-1}
    [[ "$SITE_COUNT" =~ ^[1-5]$ ]] && break
    echo "Please enter a number between 1 and 5."
done

FREE_REDIS=$(( REDIS_MAX_DB - $(echo "$REDIS_IN_USE" | wc -w) ))
NEED_REDIS=$(( SITE_COUNT * REDIS_DBS_PER_SITE ))
if [ "$FREE_REDIS" -lt "$NEED_REDIS" ]; then
    die "Need $NEED_REDIS free Redis databases, only $FREE_REDIS available (limit $REDIS_MAX_DB).
     Set 'databases 64' in /etc/redis/redis.conf and restart redis, then re-run."
fi

echo ""
read -rp "Use the SAME git repository for all sites? [Y/n]: " SHARED_REPO_ANS
SHARED_REPO_ANS=${SHARED_REPO_ANS:-y}
GIT_USER=""; GIT_TOKEN=""; SHARED_REPO_URL=""; SHARED_PRIVATE="n"
if [[ "$SHARED_REPO_ANS" =~ ^[Yy]$ ]]; then
    read -rp "Git repo URL: " SHARED_REPO_URL
    read -rp "Private repo? [Y/n]: " SHARED_PRIVATE
    SHARED_PRIVATE=${SHARED_PRIVATE:-y}
    if [[ "$SHARED_PRIVATE" =~ ^[Yy]$ ]]; then
        read -rp "Git username: " GIT_USER
        read -rsp "Git token: " GIT_TOKEN; echo ""
    fi
fi

declare -a S_DOMAIN S_SLUG S_REPO S_REPO_CLEAN S_GIT_USER S_GIT_TOKEN
declare -a S_DB_NAME S_DB_USER S_DB_PASS S_DIR S_MODE S_SSL_CERT S_SSL_KEY
declare -a S_EDITION S_CROSS

for i in $(seq 1 "$SITE_COUNT"); do
    echo ""
    echo "--- Site $i of $SITE_COUNT ---"

    while true; do
        read -rp "Domain (e.g. boss.example.com): " S_DOMAIN[$i]
        [ -n "${S_DOMAIN[$i]}" ] && break
    done

    S_SLUG[$i]=$(echo "${S_DOMAIN[$i]}" | cut -d'.' -f1 | tr -cd 'a-zA-Z0-9_-')
    S_DIR[$i]="$WEB_ROOT/${S_SLUG[$i]}"
    S_MODE[$i]="new"
    S_DB_NAME[$i]=""; S_DB_USER[$i]=""; S_DB_PASS[$i]=""
    S_SSL_CERT[$i]="$DEFAULT_SSL_CERT"; S_SSL_KEY[$i]="$DEFAULT_SSL_KEY"
    S_GIT_USER[$i]=""; S_GIT_TOKEN[$i]=""; S_REPO_CLEAN[$i]=""
    S_EDITION[$i]=""; S_CROSS[$i]=""

    # An .env alongside an artisan means a finished install. An artisan with no
    # .env means the previous run died partway; treating that as a "redeploy"
    # is what used to write an empty DB_DATABASE into a fresh .env.
    if [ -f "${S_DIR[$i]}/artisan" ] && [ -f "${S_DIR[$i]}/.env" ]; then
        echo "  !! ${S_DIR[$i]} already exists."
        read -rp "  Redeploy it instead (git pull + composer + migrate, .env & DB untouched)? [y/N]: " RD
        if [[ "${RD:-n}" =~ ^[Yy]$ ]]; then
            S_MODE[$i]="redeploy"
        else
            echo "  Skipping this site."
            S_MODE[$i]="skip"
            continue
        fi
    elif [ -d "${S_DIR[$i]}" ] && [ -n "$(ls -A "${S_DIR[$i]}" 2>/dev/null)" ]; then
        echo "  !! ${S_DIR[$i]} exists but has no .env — a previous install did not finish."
        echo "     It will be completed as a NEW install (an existing database is reused)."
        read -rp "  Continue? [y/N]: " RD
        [[ "${RD:-n}" =~ ^[Yy]$ ]] || { echo "  Skipping this site."; S_MODE[$i]="skip"; continue; }
    fi

    # Repo
    if [[ "$SHARED_REPO_ANS" =~ ^[Yy]$ ]]; then
        S_REPO_CLEAN[$i]="https://${SHARED_REPO_URL#https://}"
        if [[ "$SHARED_PRIVATE" =~ ^[Yy]$ ]]; then
            S_REPO[$i]="https://${GIT_USER}:${GIT_TOKEN}@${SHARED_REPO_URL#https://}"
            S_GIT_USER[$i]="$GIT_USER"; S_GIT_TOKEN[$i]="$GIT_TOKEN"
        else
            S_REPO[$i]="${S_REPO_CLEAN[$i]}"
        fi
    else
        read -rp "Git repo URL for this site: " SITE_REPO
        read -rp "Private repo? [Y/n]: " SITE_PRIVATE
        SITE_PRIVATE=${SITE_PRIVATE:-y}
        S_REPO_CLEAN[$i]="https://${SITE_REPO#https://}"
        if [[ "$SITE_PRIVATE" =~ ^[Yy]$ ]]; then
            read -rp "Git username: " SGU
            read -rsp "Git token: " SGT; echo ""
            S_REPO[$i]="https://${SGU}:${SGT}@${SITE_REPO#https://}"
            S_GIT_USER[$i]="$SGU"; S_GIT_TOKEN[$i]="$SGT"
        else
            S_REPO[$i]="${S_REPO_CLEAN[$i]}"
        fi
    fi

    if [ "${S_MODE[$i]}" = "new" ]; then
        read -rp "Database name [${S_SLUG[$i]}_db]: " V; S_DB_NAME[$i]="${V:-${S_SLUG[$i]}_db}"
        read -rp "Database user [${S_SLUG[$i]}_user]: " V; S_DB_USER[$i]="${V:-${S_SLUG[$i]}_user}"
        S_DB_PASS[$i]=$(rand 'a-zA-Z0-9' 20)

        # Which software this site is. Fixed for the life of the site: see
        # App\Support\Edition. Bluff sites normally take cross entries (+234).
        while true; do
            read -rp "Edition - limit or bluff [limit]: " V; V="${V:-limit}"
            [[ "$V" =~ ^(limit|bluff)$ ]] && break
            echo "Please answer limit or bluff."
        done
        S_EDITION[$i]="$V"
        if [ "$V" = "bluff" ]; then
            read -rp "Allow cross entries like +234? [Y/n]: " V; [[ "${V:-y}" =~ ^[Yy]$ ]] && S_CROSS[$i]=true || S_CROSS[$i]=false
        else
            read -rp "Allow cross entries like +234? [y/N]: " V; [[ "${V:-n}" =~ ^[Yy]$ ]] && S_CROSS[$i]=true || S_CROSS[$i]=false
        fi
    fi
done

###############################################################################
#  Shared options
###############################################################################
echo ""
echo "--- Server Options ---"
read -rp "PHP version [8.3]: " PHP_VER; PHP_VER=${PHP_VER:-8.3}

OCTANE_SERVER=""
read -rp "Install Laravel Octane? [Y/n]: " V; [[ "${V:-y}" =~ ^[Yy]$ ]] && OCTANE=y || OCTANE=n
if [ "$OCTANE" = "y" ]; then
    read -rp "Octane server - roadrunner or swoole [roadrunner]: " OCTANE_SERVER
    OCTANE_SERVER=${OCTANE_SERVER:-roadrunner}
fi
read -rp "Install Laravel Horizon? [Y/n]: "   V; [[ "${V:-y}" =~ ^[Yy]$ ]] && HORIZON=y   || HORIZON=n
read -rp "Install Laravel Reverb? [Y/n]: "    V; [[ "${V:-y}" =~ ^[Yy]$ ]] && REVERB=y    || REVERB=n
read -rp "Install Laravel Scheduler? [Y/n]: " V; [[ "${V:-y}" =~ ^[Yy]$ ]] && SCHEDULER=y || SCHEDULER=n
read -rp "Install Google Chrome (Browsershot)? [y/N]: " V; [[ "${V:-n}" =~ ^[Yy]$ ]] && CHROME=y || CHROME=n
read -rp "SSL type - cloudflare, letsencrypt, none [cloudflare]: " SSL_MODE; SSL_MODE=${SSL_MODE:-cloudflare}

###############################################################################
#  DigitalOcean Spaces - off-site backup target
#
#  One Space is shared by every site on this server; each site writes into its
#  own folder, named after APP_NAME. Same credentials for all of them.
###############################################################################
DO_KEY=""; DO_SECRET=""; DO_ENDPOINT=""; DO_REGION=""; DO_BUCKET=""; DO_URL=""
echo ""
read -rp "Configure DigitalOcean Spaces for off-site backups? [Y/n]: " V
if [[ "${V:-y}" =~ ^[Yy]$ ]]; then
    # Offer whatever an existing site already uses, so all sites stay in sync.
    EX_KEY=$(grep -h '^DO_SPACES_KEY=' "$WEB_ROOT"/*/.env 2>/dev/null | head -1 | cut -d= -f2- | tr -d '
"')
    EX_SECRET=$(grep -h '^DO_SPACES_SECRET=' "$WEB_ROOT"/*/.env 2>/dev/null | head -1 | cut -d= -f2- | tr -d '
"')
    EX_REGION=$(grep -h '^DO_SPACES_REGION=' "$WEB_ROOT"/*/.env 2>/dev/null | head -1 | cut -d= -f2- | tr -d '
"')
    EX_BUCKET=$(grep -h '^DO_SPACES_BUCKET=' "$WEB_ROOT"/*/.env 2>/dev/null | head -1 | cut -d= -f2- | tr -d '
"')

    if [ -n "$EX_KEY" ]; then
        note "reusing the Spaces credentials already configured on this server"
        DO_KEY="$EX_KEY"; DO_SECRET="$EX_SECRET"; DO_REGION="$EX_REGION"; DO_BUCKET="$EX_BUCKET"
    else
        read -rp "  Spaces access key: " DO_KEY
        read -rsp "  Spaces secret: " DO_SECRET; echo ""
        read -rp "  Region (e.g. sfo3, blr1): " DO_REGION
        read -rp "  Bucket name: " DO_BUCKET
    fi
    DO_ENDPOINT="https://${DO_REGION}.digitaloceanspaces.com"
    DO_URL="https://${DO_BUCKET}.${DO_REGION}.digitaloceanspaces.com"
    [ -n "$DO_KEY" ] && [ -n "$DO_BUCKET" ] || die "Spaces key and bucket are both required."
fi

RUN_SYSTEM=y
if [ -f "$PROVISION_MARKER" ]; then
    echo ""
    echo "  This server is already provisioned."
    read -rp "  Re-run system package install / apt upgrade? (not needed) [y/N]: " V
    [[ "${V:-n}" =~ ^[Yy]$ ]] && RUN_SYSTEM=y || RUN_SYSTEM=n
fi

if [ "$RUN_SYSTEM" = "n" ] && [ ! -d "/etc/php/$PHP_VER" ]; then
    die "PHP $PHP_VER is not installed and you declined the system install.
     Installed versions: $(ls /etc/php 2>/dev/null | tr '\n' ' ')"
fi

###############################################################################
#  SSL certificates — per site, defaulting to the shared Cloudflare origin cert
#
#  One origin cert only covers the hostnames it was issued for. A client who
#  brings their own apex domain needs their own cert, so ask per site rather
#  than hardcoding one path for the whole server.
###############################################################################
if [ "$SSL_MODE" = "cloudflare" ]; then
    echo ""
    read -rp "Do all these domains share ONE Cloudflare origin certificate? [Y/n]: " V
    if [[ "${V:-y}" =~ ^[Nn]$ ]]; then
        for i in $(seq 1 "$SITE_COUNT"); do
            [ "${S_MODE[$i]}" = "skip" ] && continue
            echo "  ${S_DOMAIN[$i]}:"
            read -rp "    cert path [$DEFAULT_SSL_CERT]: " V; S_SSL_CERT[$i]="${V:-$DEFAULT_SSL_CERT}"
            read -rp "    key  path [$DEFAULT_SSL_KEY]: "  V; S_SSL_KEY[$i]="${V:-$DEFAULT_SSL_KEY}"
        done
    fi

    for i in $(seq 1 "$SITE_COUNT"); do
        [ "${S_MODE[$i]}" = "skip" ] && continue
        if [ ! -f "${S_SSL_CERT[$i]}" ] || [ ! -f "${S_SSL_KEY[$i]}" ]; then
            echo ""
            echo "  Origin cert for ${S_DOMAIN[$i]} not found. Create it now:"
            echo "    Cloudflare -> SSL/TLS -> Origin Server -> Create Certificate"
            echo "    nano ${S_SSL_CERT[$i]}"
            echo "    nano ${S_SSL_KEY[$i]}"
            read -rp "  Press ENTER when done..." _
            { [ -f "${S_SSL_CERT[$i]}" ] && [ -f "${S_SSL_KEY[$i]}" ]; } \
                || die "cert files still missing for ${S_DOMAIN[$i]}."
        fi
        chmod 600 "${S_SSL_KEY[$i]}" 2>/dev/null || true
    done
fi

###############################################################################
#  Pre-allocate ports / redis DBs, then show summary
###############################################################################
declare -a S_OPORT S_RPORT S_RDB S_RCDB S_RQDB
for i in $(seq 1 "$SITE_COUNT"); do
    S_OPORT[$i]=""; S_RPORT[$i]=""; S_RDB[$i]=""; S_RCDB[$i]=""; S_RQDB[$i]=""
    [ "${S_MODE[$i]}" = "skip" ] && continue

    if [ "${S_MODE[$i]}" = "redeploy" ]; then
        REG=$(registry_file "${S_SLUG[$i]}")
        ENVF="${S_DIR[$i]}/.env"
        S_OPORT[$i]=$(grep -ho -- '--port=[0-9]*' "/etc/supervisor/conf.d/octane_${S_SLUG[$i]}.conf" 2>/dev/null | cut -d= -f2 || true)
        S_RPORT[$i]=$(grep -ho -- '--port=[0-9]*' "/etc/supervisor/conf.d/reverb_${S_SLUG[$i]}.conf" 2>/dev/null | cut -d= -f2 || true)
        if [ -z "${S_OPORT[$i]}" ] && [ -f "$REG" ]; then S_OPORT[$i]=$(grep '^OCTANE_PORT=' "$REG" | cut -d= -f2 || true); fi
        if [ -z "${S_RPORT[$i]}" ] && [ -f "$REG" ]; then S_RPORT[$i]=$(grep '^REVERB_PORT=' "$REG" | cut -d= -f2 || true); fi
        S_RDB[$i]=$(env_get REDIS_DB "$ENVF")
        S_RCDB[$i]=$(env_get REDIS_CACHE_DB "$ENVF")
        S_RQDB[$i]=$(env_get REDIS_QUEUE_DB "$ENVF")

        # A redeploy with no discoverable Octane port would write --port= and
        # let Octane fall back to 8000, stealing another site's port.
        if [ "$OCTANE" = "y" ] && [ -z "${S_OPORT[$i]}" ]; then
            alloc_port 8000; S_OPORT[$i]=$ALLOC_PORT
            note "${S_SLUG[$i]}: no existing Octane port found — allocating ${S_OPORT[$i]}"
        fi
        if [ "$REVERB" = "y" ] && [ -z "${S_RPORT[$i]}" ]; then
            alloc_port 8080; S_RPORT[$i]=$ALLOC_PORT
            note "${S_SLUG[$i]}: no existing Reverb port found — allocating ${S_RPORT[$i]}"
        fi
        continue
    fi

    alloc_port 8000; S_OPORT[$i]=$ALLOC_PORT
    alloc_port 8080; S_RPORT[$i]=$ALLOC_PORT
    alloc_redis;     S_RDB[$i]=$ALLOC_REDIS
    alloc_redis;     S_RCDB[$i]=$ALLOC_REDIS
    alloc_redis;     S_RQDB[$i]=$ALLOC_REDIS
done

# Last line of defence, before anything is installed: no site in this run may
# use a port another site already claims. A redeploy keeps whatever port its
# supervisor conf has, so a clash made earlier (or by hand) would otherwise be
# carried forward, leaving one of the two sites unable to start.
for i in $(seq 1 "$SITE_COUNT"); do
    [ "${S_MODE[$i]}" = "skip" ] && continue
    for port in "${S_OPORT[$i]}" "${S_RPORT[$i]}"; do
        [ -n "$port" ] || continue
        OWNER=$(port_owner "$port" "${S_SLUG[$i]}")
        [ -z "$OWNER" ] || die "${S_SLUG[$i]} would use port $port, which site '$OWNER' already uses.
     Only one of them can run. Give ${S_SLUG[$i]} a free port in
     $SUP_DIR/octane_${S_SLUG[$i]}.conf / reverb_${S_SLUG[$i]}.conf, its nginx config
     and REVERB_PORT / REVERB_SERVER_PORT in its .env, then re-run."
    done
done

echo ""
echo "=============================================="
echo "  Summary"
echo "=============================================="
echo "  PHP $PHP_VER | Octane: $OCTANE ${OCTANE_SERVER:-} | Horizon: $HORIZON | Reverb: $REVERB | Scheduler: $SCHEDULER | Chrome: $CHROME"
echo "  SSL: $SSL_MODE | System install: $RUN_SYSTEM"
echo ""
for i in $(seq 1 "$SITE_COUNT"); do
    [ "${S_MODE[$i]}" = "skip" ] && { echo "  Site $i : SKIPPED"; continue; }
    echo "  Site $i : https://${S_DOMAIN[$i]}   [${S_MODE[$i]}]"
    echo "    Dir   : ${S_DIR[$i]}"
    [ "${S_MODE[$i]}" = "new" ] && echo "    DB    : ${S_DB_NAME[$i]} / ${S_DB_USER[$i]}"
    [ "${S_MODE[$i]}" = "new" ] && echo "    App   : ${S_EDITION[$i]} edition, cross entries ${S_CROSS[$i]}"
    echo "    Redis : db ${S_RDB[$i]} / cache ${S_RCDB[$i]} / queue ${S_RQDB[$i]}"
    [ "$OCTANE" = "y" ] && echo "    Octane: port ${S_OPORT[$i]}"
    [ "$REVERB" = "y" ] && echo "    Reverb: port ${S_RPORT[$i]}"
    [ "$SSL_MODE" = "cloudflare" ] && echo "    Cert  : ${S_SSL_CERT[$i]}"
done
echo "=============================================="
read -rp "Start installation? [Y/n]: " V
[[ "${V:-y}" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 1; }

###############################################################################
#  [1/6] System packages
###############################################################################
if [ "$RUN_SYSTEM" = "y" ]; then
    echo "[1/6] System packages..."
    export DEBIAN_FRONTEND=noninteractive
    export NEEDRESTART_MODE=a
    apt update
    apt upgrade -y -o Dpkg::Options::="--force-confold" -o Dpkg::Options::="--force-confdef"
    apt install -y curl git unzip zip wget gnupg ca-certificates software-properties-common acl iproute2 ufw

    if ! id "$APP_USER" &>/dev/null; then
        adduser --disabled-password --gecos "" "$APP_USER"
        usermod -aG www-data "$APP_USER"
        usermod -aG sudo "$APP_USER"
    fi

    echo "[2/6] PHP ${PHP_VER}..."
    add-apt-repository ppa:ondrej/php -y
    apt update
    apt install -y php${PHP_VER} php${PHP_VER}-fpm php${PHP_VER}-cli php${PHP_VER}-mbstring \
        php${PHP_VER}-xml php${PHP_VER}-bcmath php${PHP_VER}-curl php${PHP_VER}-zip \
        php${PHP_VER}-gd php${PHP_VER}-intl php${PHP_VER}-mysql php${PHP_VER}-redis \
        php${PHP_VER}-sockets php${PHP_VER}-opcache
    [ "${OCTANE_SERVER:-}" = "swoole" ] && apt install -y php${PHP_VER}-swoole

    command -v composer &>/dev/null || {
        curl -sS https://getcomposer.org/installer | php
        mv composer.phar /usr/local/bin/composer && chmod +x /usr/local/bin/composer
    }
    command -v node &>/dev/null || {
        curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
        apt install -y nodejs
    }

    apt install -y nginx supervisor mysql-server redis-server
    systemctl enable --now nginx supervisor mysql redis-server

    # 16 Redis databases caps this server at 5 sites (3 each). Raise it while
    # the box is still empty; on a live server a redis restart would drop every
    # session and every queued job, so we only warn there.
    if [ -f /etc/redis/redis.conf ]; then
        if [ ${#EXISTING_SITES[@]} -eq 0 ]; then
            if ! grep -qE '^databases 64$' /etc/redis/redis.conf; then
                sed -i 's/^databases .*/databases 64/' /etc/redis/redis.conf
                grep -qE '^databases ' /etc/redis/redis.conf || echo 'databases 64' >> /etc/redis/redis.conf
                systemctl restart redis-server
            fi
        elif [ "$(redis_max_db)" -lt 64 ]; then
            note "redis has only $(redis_max_db) databases (5 sites max)."
            note "To raise it later: set 'databases 64' in /etc/redis/redis.conf and"
            note "restart redis on a quiet day — a restart drops sessions and queues."
        fi
    fi

    if [ ! -f /swapfile ]; then
        fallocate -l 2G /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile
        echo '/swapfile none swap sw 0 0' >> /etc/fstab
        grep -q '^vm.swappiness' /etc/sysctl.conf || echo 'vm.swappiness=10' >> /etc/sysctl.conf
        sysctl -p
    fi

    if [ "$CHROME" = "y" ] && ! command -v google-chrome &>/dev/null; then
        apt install -y fonts-liberation libatk-bridge2.0-0 libatk1.0-0 libcairo2 libcups2 \
            libdbus-1-3 libgbm1 libgtk-3-0 libnspr4 libnss3 libpango-1.0-0 libxcomposite1 \
            libxdamage1 libxrandr2 xdg-utils libasound2t64 libx11-xcb1 libxss1
        wget -q https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb
        apt install -y ./google-chrome-stable_current_amd64.deb
        rm -f google-chrome-stable_current_amd64.deb
        sysctl -w kernel.apparmor_restrict_unprivileged_userns=0 || true
        grep -qxF 'kernel.apparmor_restrict_unprivileged_userns = 0' /etc/sysctl.conf \
            || echo "kernel.apparmor_restrict_unprivileged_userns = 0" >> /etc/sysctl.conf
        sysctl -p || true
        mkdir -p /var/www/.cache/puppeteer
        chown -R www-data:www-data /var/www/.cache
    fi

    rm -f /etc/nginx/sites-enabled/default
    touch "$PROVISION_MARKER"
else
    echo "[1/6] System already provisioned — skipping apt (no downtime for live sites)."
fi

###############################################################################
#  Cloudflare real client IP
#
#  Without this every request appears to come from a Cloudflare edge address:
#  rate limiting throttles all users as one, and audit logs record the CDN.
###############################################################################
if [ "$SSL_MODE" = "cloudflare" ]; then
    CF_CONF="/etc/nginx/conf.d/00-cloudflare-realip.conf"
    CF_V4=$(curl -fsS --max-time 10 https://www.cloudflare.com/ips-v4 2>/dev/null || true)
    CF_V6=$(curl -fsS --max-time 10 https://www.cloudflare.com/ips-v6 2>/dev/null || true)
    if [ -z "$CF_V4" ]; then
        note "could not fetch cloudflare.com/ips — using the built-in list"
        CF_V4="173.245.48.0/20
103.21.244.0/22
103.22.200.0/22
103.31.4.0/22
141.101.64.0/18
108.162.192.0/18
190.93.240.0/20
188.114.96.0/20
197.234.240.0/22
198.41.128.0/17
162.158.0.0/15
104.16.0.0/13
104.24.0.0/14
172.64.0.0/13
131.0.72.0/22"
        CF_V6="2400:cb00::/32
2606:4700::/32
2803:f800::/32
2405:b500::/32
2405:8100::/32
2a06:98c0::/29
2c0f:f248::/32"
    fi
    {
        echo "# Generated by deploy.sh on $(date). Refresh from cloudflare.com/ips"
        printf '%s\n%s\n' "$CF_V4" "$CF_V6" | grep -E '^[0-9a-fA-F.:]+/[0-9]+$' | sed 's|^|set_real_ip_from |; s|$|;|'
        echo "real_ip_header CF-Connecting-IP;"
    } > "$CF_CONF"
fi

###############################################################################
#  [3/6] Per-site setup
###############################################################################
echo "[3/6] Setting up sites..."

HTTP2_STYLE=$(nginx_http2_directive)

# write_prog NAME COMMAND STOPWAIT SLUG APP_DIR
#
# startsecs/startretries: supervisor's defaults give up after 3 quick failures
# and leave the program FATAL — a site that is merely slow to warm up stays
# down until someone notices. Log caps: the default is 50MB x 10 backups PER
# PROGRAM, which is ~6GB of logs across four programs and three sites.
write_prog() {
    local name="$1" cmd="$2" stopwait="$3" slug="$4" dir="$5"
    cat > "/etc/supervisor/conf.d/${name}_${slug}.conf" << SUPEOF
[program:${name}_${slug}]
process_name=%(program_name)s
directory=${dir}
command=${cmd}
autostart=true
autorestart=true
startsecs=5
startretries=10
stopasgroup=true
killasgroup=true
stopsignal=TERM
user=www-data
environment=HOME="/var/www",USER="www-data"
redirect_stderr=true
stdout_logfile=${dir}/storage/logs/${name}.log
stdout_logfile_maxbytes=10MB
stdout_logfile_backups=3
stopwaitsecs=${stopwait}
SUPEOF
}

for i in $(seq 1 "$SITE_COUNT"); do
    [ "${S_MODE[$i]}" = "skip" ] && continue

    DOMAIN="${S_DOMAIN[$i]}"; SLUG="${S_SLUG[$i]}"; APP_DIR="${S_DIR[$i]}"
    OPORT="${S_OPORT[$i]:-}"; RPORT="${S_RPORT[$i]:-}"
    MODE="${S_MODE[$i]}"

    echo ""
    echo ">>> ${DOMAIN}  (${APP_DIR})"

    # ---------- MySQL (new sites only) ----------
    if [ "$MODE" = "new" ]; then
        mysql -e "CREATE DATABASE IF NOT EXISTS \`${S_DB_NAME[$i]}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
        mysql -e "CREATE USER IF NOT EXISTS '${S_DB_USER[$i]}'@'localhost' IDENTIFIED BY '${S_DB_PASS[$i]}';"
        mysql -e "ALTER USER '${S_DB_USER[$i]}'@'localhost' IDENTIFIED BY '${S_DB_PASS[$i]}';"
        mysql -e "GRANT ALL PRIVILEGES ON \`${S_DB_NAME[$i]}\`.* TO '${S_DB_USER[$i]}'@'localhost';"
        mysql -e "FLUSH PRIVILEGES;"
    fi

    # ---------- Code ----------
    mkdir -p "$WEB_ROOT"
    # --system, not --global. Root runs git here, but composer runs as
    # $APP_USER and www-data runs artisan, and each user has its own
    # gitconfig. A --global entry only covers root, so composer warns about
    # "dubious ownership" on every single deploy.
    git config --system --get-all safe.directory 2>/dev/null | grep -qx "$APP_DIR" || git config --system --add safe.directory "$APP_DIR"

    if [ -d "${APP_DIR}/.git" ]; then
        git -C "$APP_DIR" pull
    else
        git clone "${S_REPO[$i]}" "$APP_DIR"
    fi

    # The clone URL carries the token, and git writes it verbatim into
    # .git/config. Every site runs as www-data, so that file is readable by
    # every other site on this box — one compromised tenant walks off with the
    # PAT. Keep the credential in a root-only store instead.
    if [ -n "${S_GIT_TOKEN[$i]}" ]; then
        git -C "$APP_DIR" remote set-url origin "${S_REPO_CLEAN[$i]}"
        GIT_HOST=$(echo "${S_REPO_CLEAN[$i]}" | sed 's|https://||; s|/.*||')
        CRED_LINE="https://${S_GIT_USER[$i]}:${S_GIT_TOKEN[$i]}@${GIT_HOST}"
        touch /root/.git-credentials; chmod 600 /root/.git-credentials
        grep -qxF "$CRED_LINE" /root/.git-credentials || echo "$CRED_LINE" >> /root/.git-credentials
        git config --global credential.helper store
    fi

    chown -R "$APP_USER":www-data "$APP_DIR"
    cd "$APP_DIR"

    # ---------- .env ----------
    if [ ! -f .env ]; then
        [ -f .env.example ] || die "$APP_DIR has no .env.example to copy."
        cp .env.example .env
        chown "$APP_USER":www-data .env
        chmod 640 .env
        env_set APP_NAME              "\"${SLUG}\""            .env
        env_set APP_ENV               production               .env
        env_set APP_DEBUG             false                    .env
        env_set APP_URL               "https://${DOMAIN}"      .env
        env_set ASSET_URL             "https://${DOMAIN}"      .env
        env_set DB_DATABASE           "${S_DB_NAME[$i]}"       .env
        env_set DB_USERNAME           "${S_DB_USER[$i]}"       .env
        env_set DB_PASSWORD           "${S_DB_PASS[$i]}"       .env
        env_set QUEUE_CONNECTION      redis                    .env
        env_set CACHE_STORE           redis                    .env
        env_set SESSION_DRIVER        redis                    .env
        # .env.example ships LOG_LEVEL=debug, which on a production draw night
        # writes gigabytes into storage/logs.
        env_set LOG_CHANNEL           daily                    .env
        env_set LOG_STACK             daily                    .env
        env_set LOG_LEVEL             warning                  .env
        env_set LOG_DAILY_DAYS        14                       .env
        # --- isolation between sites sharing one Redis instance ---
        # All THREE db indexes must be pinned. config/database.php defaults the
        # queue connection to db 3; leaving it unset puts every site's queue in
        # db 3 while another site holds db 3 as its cache — and Laravel's redis
        # cache flush is a FLUSHDB, so that site's `cache:clear` (which
        # `optimize:clear`, and therefore every deploy, calls) wipes the other
        # sites' pending jobs.
        env_set REDIS_CLIENT          phpredis                 .env
        env_set REDIS_DB              "${S_RDB[$i]}"           .env
        env_set REDIS_CACHE_DB        "${S_RCDB[$i]}"          .env
        env_set REDIS_QUEUE_DB        "${S_RQDB[$i]}"          .env
        env_set REDIS_PREFIX          "${SLUG}_db_"            .env
        env_set CACHE_PREFIX          "${SLUG}_cache_"         .env
        env_set HORIZON_PREFIX        "${SLUG}_horizon:"       .env
        if [ -n "$DO_KEY" ]; then
            env_set DO_SPACES_KEY      "$DO_KEY"      .env
            env_set DO_SPACES_SECRET   "$DO_SECRET"   .env
            env_set DO_SPACES_ENDPOINT "$DO_ENDPOINT" .env
            env_set DO_SPACES_REGION   "$DO_REGION"   .env
            env_set DO_SPACES_BUCKET   "$DO_BUCKET"   .env
            env_set DO_SPACES_URL      "$DO_URL"      .env
            env_set DO_SPACES_BACKUP_PREFIX "backups"  .env
        fi
        [ "$OCTANE" = "y" ] && env_set OCTANE_SERVER "${OCTANE_SERVER}" .env
        env_set APP_EDITION           "${S_EDITION[$i]:-limit}" .env
        env_set CROSS_ENTRIES         "${S_CROSS[$i]:-false}"   .env

        if [ "$REVERB" = "y" ]; then
            R_ID=$(rand '0-9' 6); R_KEY=$(rand 'a-z0-9' 20); R_SEC=$(rand 'a-z0-9' 40)
            env_set BROADCAST_CONNECTION reverb              .env
            env_set REVERB_APP_ID        "$R_ID"             .env
            env_set REVERB_APP_KEY       "$R_KEY"            .env
            env_set REVERB_APP_SECRET    "$R_SEC"            .env
            env_set REVERB_HOST          "127.0.0.1"         .env
            env_set REVERB_PORT          "$RPORT"            .env
            env_set REVERB_SCHEME        http                .env
            env_set REVERB_SERVER_HOST   "127.0.0.1"         .env
            env_set REVERB_SERVER_PORT   "$RPORT"            .env
            env_set REVERB_ALLOWED_ORIGINS "https://${DOMAIN}" .env
            env_set VITE_REVERB_APP_KEY  "$R_KEY"            .env
            env_set VITE_REVERB_HOST     "${DOMAIN}"         .env
            env_set VITE_REVERB_PORT     443                 .env
            env_set VITE_REVERB_SCHEME   https               .env
        fi
    else
        echo "  .env exists — left untouched"
        while IFS= read -r problem; do
            [ -n "$problem" ] && echo "  WARNING: $problem"
        done < <(env_isolation_problems .env)
    fi

    # ---------- Dependencies ----------
    as_app composer install --no-dev --optimize-autoloader --no-interaction

    # Only require what is genuinely absent. `composer require` on a package
    # already in composer.json re-resolves and rewrites composer.lock, and the
    # next `git pull` on this server then fails with a merge conflict.
    REQUIRED_NOW=""
    for pkg_flag in "laravel/octane:$OCTANE" "laravel/horizon:$HORIZON" "laravel/reverb:$REVERB"; do
        pkg="${pkg_flag%:*}"; flag="${pkg_flag##*:}"
        if [ "$flag" = "y" ] && ! composer_has "$pkg" "$APP_DIR"; then
            note "composer require $pkg (not in composer.json)"
            as_app composer require "$pkg" --no-interaction
            REQUIRED_NOW="$REQUIRED_NOW $pkg"
        fi
    done

    # A fresh install always builds. public/build is only partially tracked in
    # this repo, so a checked-out manifest.json cannot be trusted to match the
    # hashed bundles actually present on disk.
    if [ -f package.json ]; then
        if [ -f package-lock.json ]; then as_app npm ci --no-audit --no-fund
        else as_app npm install --no-audit --no-fund; fi
        as_app npm run build
    fi

    # The manifest must exist AND every file it names must be on disk, or the
    # site serves pages whose CSS and JS all 404.
    if [ -f package.json ] && [ -d resources ]; then
        if [ ! -f public/build/manifest.json ]; then
            die "no public/build/manifest.json for ${DOMAIN}. Every page would 500.
     Fix the vite build — most often out of memory, check 'free -m'."
        fi
        MISSING_ASSET=""
        while IFS= read -r f; do
            [ -n "$f" ] && [ ! -f "public/build/$f" ] && MISSING_ASSET="$f"
        done < <(grep -o '"file":"[^"]*"' public/build/manifest.json | sed 's/^"file":"//; s/"$//')
        [ -n "$MISSING_ASSET" ] && die "public/build/manifest.json for ${DOMAIN} names
     'public/build/${MISSING_ASSET}', which is not on disk. Every page would 404
     its CSS and JS. Re-run 'npm run build' in ${APP_DIR}."
    fi

    # ---------- Ownership BEFORE artisan, so no root-owned cache files ----------
    chown -R www-data:www-data "$APP_DIR"
    # Directories need the execute bit; files must NOT get it. `chmod -R 775`
    # set it on everything, which flipped the tracked .gitignore files under
    # storage/ from 100644 to 100755 and left git reporting a dirty tree on
    # every site forever after.
    find storage bootstrap/cache -type d -exec chmod 775 {} +
    find storage bootstrap/cache -type f -exec chmod 664 {} +
    chmod 640 .env
    # We deliberately chmod files the repo also tracks, so stop git treating a
    # permission change as a modification.
    git -C "$APP_DIR" config core.fileMode false
    setfacl -R  -m u:"$APP_USER":rwX "$APP_DIR"
    setfacl -R -d -m u:"$APP_USER":rwX "$APP_DIR"

    # ---------- Artisan (as www-data = the runtime user) ----------
    if ! grep -q '^APP_KEY=base64:' .env; then
        as_web php${PHP_VER} artisan key:generate --force
    fi
    as_web php${PHP_VER} artisan migrate --force
    as_web php${PHP_VER} artisan storage:link || true

    if [ "$OCTANE" = "y" ]; then
        as_web php${PHP_VER} artisan octane:install --server="$OCTANE_SERVER" --no-interaction || true
        if [ "$OCTANE_SERVER" = "roadrunner" ] && [ ! -f "${APP_DIR}/rr" ]; then
            as_web ./vendor/bin/rr get-binary || true
        fi
        [ -f .rr.yaml ] || touch .rr.yaml
        chown www-data:www-data .rr.yaml && chmod 664 .rr.yaml
    fi
    [ "$HORIZON" = "y" ] && { as_web php${PHP_VER} artisan horizon:install --no-interaction || true; }
    # reverb:install publishes config/reverb.php and npm-installs Echo, which
    # rewrites package-lock.json — two changes to a checkout that the next
    # `git pull` refuses to overwrite. An app that already ships Reverb needs
    # neither: the package's own config reads the REVERB_* keys set above.
    if [ "$REVERB" = "y" ]; then
        if [[ " $REQUIRED_NOW " == *" laravel/reverb "* ]]; then
            as_web php${PHP_VER} artisan reverb:install --no-interaction || true
        else
            note "Reverb is already part of the app — skipping reverb:install"
        fi
    fi

    if [ "$CHROME" = "y" ]; then
        as_web env PUPPETEER_CACHE_DIR=/var/www/.cache/puppeteer npx --prefix "$APP_DIR" puppeteer browsers install chrome-headless-shell || true
        as_web env PUPPETEER_CACHE_DIR=/var/www/.cache/puppeteer npx --prefix "$APP_DIR" puppeteer browsers install chrome || true
        chmod -R 755 /var/www/.cache/puppeteer
    fi

    as_web php${PHP_VER} artisan config:cache
    as_web php${PHP_VER} artisan route:cache
    as_web php${PHP_VER} artisan view:cache
    as_web php${PHP_VER} artisan event:cache || true

    ###########################################################################
    #  Supervisor
    ###########################################################################
    [ "$OCTANE" = "y" ] && write_prog octane \
        "/usr/bin/php${PHP_VER} ${APP_DIR}/artisan octane:start --server=${OCTANE_SERVER} --host=127.0.0.1 --port=${OPORT}" 10 "$SLUG" "$APP_DIR"
    [ "$HORIZON" = "y" ] && write_prog horizon \
        "/usr/bin/php${PHP_VER} ${APP_DIR}/artisan horizon" 3600 "$SLUG" "$APP_DIR"
    [ "$SCHEDULER" = "y" ] && write_prog scheduler \
        "/usr/bin/php${PHP_VER} ${APP_DIR}/artisan schedule:work --no-interaction" 60 "$SLUG" "$APP_DIR"
    [ "$REVERB" = "y" ] && write_prog reverb \
        "/usr/bin/php${PHP_VER} ${APP_DIR}/artisan reverb:start --host=127.0.0.1 --port=${RPORT}" 3600 "$SLUG" "$APP_DIR"

    ###########################################################################
    #  Nginx
    ###########################################################################
    NGINX_CONF="/etc/nginx/sites-available/${SLUG}_${DOMAIN}.conf"
    if [ ! -f "$NGINX_CONF" ]; then

        # www.cm1.example.com is not a hostname anyone will resolve, and
        # Cloudflare will have no record for it. Only add www for apex domains.
        SERVER_NAMES="$DOMAIN"
        [ "$(echo "$DOMAIN" | tr -cd '.' | wc -c)" -le 1 ] && SERVER_NAMES="$DOMAIN www.$DOMAIN"

        REVERB_BLOCK=""
        [ "$REVERB" = "y" ] && REVERB_BLOCK="
    location /app {
        proxy_http_version 1.1;
        proxy_set_header Host \$http_host;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \"Upgrade\";
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_read_timeout 3600s;
        proxy_pass http://127.0.0.1:${RPORT};
    }"

        if [ "$OCTANE" = "y" ]; then
            PHP_BACKEND="
    location ~* \.(js|css|png|jpg|jpeg|gif|ico|svg|woff|woff2|ttf|eot|map|webp)\$ {
        expires max;
        access_log off;
        log_not_found off;
        try_files \$uri @octane;
    }
    location / { try_files \$uri @octane; }
    location @octane {
        proxy_http_version 1.1;
        proxy_set_header Host \$http_host;
        proxy_set_header Real-IP \$remote_addr;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 300s;
        proxy_pass http://127.0.0.1:${OPORT};
    }"
        else
            PHP_BACKEND="
    location / { try_files \$uri \$uri/ /index.php?\$query_string; }
    location ~ \.php\$ {
        fastcgi_pass unix:/var/run/php/php${PHP_VER}-fpm.sock;
        fastcgi_param SCRIPT_FILENAME \$realpath_root\$fastcgi_script_name;
        fastcgi_read_timeout 300;
        include fastcgi_params;
    }"
        fi

        COMMON="
    root ${APP_DIR}/public;
    index index.php;
    charset utf-8;
    client_max_body_size 100M;
    add_header X-Frame-Options SAMEORIGIN;
    add_header X-Content-Type-Options nosniff;
${REVERB_BLOCK}
${PHP_BACKEND}
    location = /favicon.ico { access_log off; log_not_found off; }
    location = /robots.txt  { access_log off; log_not_found off; }
    location ~ /\.(?!well-known).* { deny all; }"

        if [ "$SSL_MODE" = "cloudflare" ]; then
            # `http2 on;` only exists from nginx 1.25.1. On older builds it is a
            # hard config error, which would break EVERY site at the next reload.
            if [ "$HTTP2_STYLE" = "modern" ]; then
                LISTEN_443="    listen 443 ssl;
    http2 on;"
            else
                LISTEN_443="    listen 443 ssl http2;"
            fi
            cat > "$NGINX_CONF" << NGXEOF
server {
    listen 80;
    server_name ${SERVER_NAMES};
    return 301 https://\$host\$request_uri;
}
server {
${LISTEN_443}
    server_name ${SERVER_NAMES};
    ssl_certificate     ${S_SSL_CERT[$i]};
    ssl_certificate_key ${S_SSL_KEY[$i]};
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;
${COMMON}
}
NGXEOF
        else
            cat > "$NGINX_CONF" << NGXEOF
server {
    listen 80;
    server_name ${SERVER_NAMES};
${COMMON}
}
NGXEOF
        fi

        ln -sf "$NGINX_CONF" "/etc/nginx/sites-enabled/${SLUG}_${DOMAIN}.conf"

        # Validate immediately, while we still know which site broke it. The
        # symlink comes back out on failure so the other sites keep serving.
        if ! nginx -t; then
            rm -f "/etc/nginx/sites-enabled/${SLUG}_${DOMAIN}.conf"
            die "nginx rejected the config generated for ${DOMAIN}.
     It is kept at $NGINX_CONF for inspection; the symlink was removed so the
     other sites are unaffected."
        fi

        if [ "$SSL_MODE" = "letsencrypt" ]; then
            apt install -y certbot python3-certbot-nginx
            nginx_apply
            certbot --nginx -d "$DOMAIN" --non-interactive --agree-tos -m "admin@${DOMAIN}"
        fi
    else
        echo "  Nginx config exists — skipping"
    fi

    # ---------- Registry ----------
    # Source of truth for --list, --remove and future port/redis allocation, so
    # it records everything needed to undo the install.
    cat > "$(registry_file "$SLUG")" << REGEOF
SLUG=${SLUG}
DOMAIN=${DOMAIN}
DIR=${APP_DIR}
PHP_VER=${PHP_VER}
OCTANE=${OCTANE}
OCTANE_SERVER=${OCTANE_SERVER:-}
OCTANE_PORT=${OPORT}
HORIZON=${HORIZON}
REVERB=${REVERB}
REVERB_PORT=${RPORT}
SCHEDULER=${SCHEDULER}
REDIS_DB=${S_RDB[$i]}
REDIS_CACHE_DB=${S_RCDB[$i]}
REDIS_QUEUE_DB=${S_RQDB[$i]}
DB_NAME=$(env_get DB_DATABASE "$APP_DIR/.env")
DB_USER=$(env_get DB_USERNAME "$APP_DIR/.env")
SSL_MODE=${SSL_MODE}
SSL_CERT=${S_SSL_CERT[$i]}
SSL_KEY=${S_SSL_KEY[$i]}
NGINX_CONF=${NGINX_CONF}
CREATED=$(date +%F)
REGEOF
    chmod 600 "$(registry_file "$SLUG")"

    echo ">>> ${DOMAIN} done."
done

cd /

###############################################################################
#  [4/6] Cross-DB grants across ALL sites on the server
###############################################################################
echo "[4/6] Cross-database grants..."
declare -a CDB_NAMES=() CDB_USERS=()
for d in "$WEB_ROOT"/*/; do
    [ -f "${d}.env" ] || continue
    N=$(env_get DB_DATABASE "${d}.env")
    U=$(env_get DB_USERNAME "${d}.env")
    [ -n "$N" ] && [ -n "$U" ] && { CDB_NAMES+=("$N"); CDB_USERS+=("$U"); }
done
TOTAL=${#CDB_NAMES[@]}
if [ "$TOTAL" -gt 1 ]; then
    for ((a = 0; a < TOTAL; a++)); do
        for ((b = 0; b < TOTAL; b++)); do
            [ "$a" = "$b" ] && continue
            mysql -e "GRANT SELECT, DELETE ON \`${CDB_NAMES[$b]}\`.* TO '${CDB_USERS[$a]}'@'localhost';" 2>/dev/null \
                && echo "  ${CDB_USERS[$a]} -> SELECT,DELETE on ${CDB_NAMES[$b]}" || true
        done
    done
    mysql -e "FLUSH PRIVILEGES;"
fi

###############################################################################
#  [5/6] Start / reload services
###############################################################################
echo "[5/6] Starting services..."
supervisorctl reread
supervisorctl update

# A redeploy usually rewrites the supervisor conf with identical content, so
# `update` sees no change and restarts nothing — and Octane, Horizon and Reverb
# all hold the application in memory. Without an explicit restart the deploy
# finishes cleanly while the old code keeps serving.
for i in $(seq 1 "$SITE_COUNT"); do
    [ "${S_MODE[$i]}" = "redeploy" ] || continue
    echo "  Restarting workers for ${S_SLUG[$i]} (redeploy)"
    for p in $(site_programs "${S_SLUG[$i]}"); do
        if supervisorctl restart "$p" >/dev/null 2>&1; then echo "    $p"; else echo "    $p (restart FAILED)"; fi
    done
done

nginx_apply

# Keep whatever port sshd actually listens on rather than assuming 22, so
# enabling ufw cannot lock us out of the box.
SSH_PORT=$(grep -E '^[[:space:]]*Port[[:space:]]+[0-9]+' /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' | head -1)
[ -z "$SSH_PORT" ] && SSH_PORT=22
ufw allow "$SSH_PORT"/tcp >/dev/null 2>&1 || true
ufw allow OpenSSH >/dev/null 2>&1 || true
ufw allow 'Nginx Full' >/dev/null
ufw --force enable >/dev/null

###############################################################################
#  [6/6] Health check
#
#  "DONE!" used to print whether or not anything actually came up.
###############################################################################
echo "[6/6] Health check..."
sleep 8
HEALTH_FAIL=0
for i in $(seq 1 "$SITE_COUNT"); do
    [ "${S_MODE[$i]}" = "skip" ] && continue
    SLUG="${S_SLUG[$i]}"
    echo ""
    echo "  ${S_DOMAIN[$i]}"
    for p in $(site_programs "$SLUG"); do
        ST=$(supervisorctl status "$p" 2>/dev/null | awk '{print $2}')
        if [ "$ST" = "RUNNING" ]; then
            echo "    OK    $p"
        else
            echo "    FAIL  $p ($ST)  ->  tail ${S_DIR[$i]}/storage/logs/${p%%_*}.log"
            HEALTH_FAIL=1
        fi
    done
    if [ "$OCTANE" = "y" ] && [ -n "${S_OPORT[$i]}" ]; then
        if curl -sf -o /dev/null --max-time 10 "http://127.0.0.1:${S_OPORT[$i]}/up" \
        || curl -sf -o /dev/null --max-time 10 "http://127.0.0.1:${S_OPORT[$i]}/"; then
            echo "    OK    http probe on port ${S_OPORT[$i]}"
        else
            echo "    FAIL  http probe on port ${S_OPORT[$i]} — Octane is not answering"
            HEALTH_FAIL=1
        fi
    fi

    # The deploy command refuses to `git pull` over local changes, so anything
    # an installer wrote into the checkout blocks the very next deploy.
    DIRTY=$(git -C "${S_DIR[$i]}" status --porcelain 2>/dev/null || true)
    if [ -n "$DIRTY" ]; then
        echo "    WARN  the checkout has local changes — the next deploy will refuse to pull:"
        echo "$DIRTY" | sed 's/^/            /'
        echo "          Review: git -C ${S_DIR[$i]} diff"
        echo "          Discard a changed file: git -C ${S_DIR[$i]} checkout -- FILE  (delete '??' files by hand)"
        HEALTH_FAIL=1
    fi
done

###############################################################################
#  Done
###############################################################################
{
    echo ""
    echo "===== $(date) ====="
    for i in $(seq 1 "$SITE_COUNT"); do
        [ "${S_MODE[$i]}" = "new" ] || continue
        echo "Site      : https://${S_DOMAIN[$i]}"
        echo "  Dir     : ${S_DIR[$i]}"
        echo "  DB Name : ${S_DB_NAME[$i]}"
        echo "  DB User : ${S_DB_USER[$i]}"
        echo "  DB Pass : ${S_DB_PASS[$i]}"
        echo "  Octane  : ${S_OPORT[$i]}   Reverb: ${S_RPORT[$i]}"
        echo "  Redis   : db ${S_RDB[$i]} / cache ${S_RCDB[$i]} / queue ${S_RQDB[$i]}"
    done
} >> "$CRED_FILE"
chmod 600 "$CRED_FILE"

echo ""
echo "=============================================="
if [ "$HEALTH_FAIL" = 0 ]; then
    echo "  DONE — all services running."
else
    echo "  DONE, BUT SOMETHING NEEDS ATTENTION (see FAIL / WARN above)."
fi
echo "=============================================="
for i in $(seq 1 "$SITE_COUNT"); do
    [ "${S_MODE[$i]}" = "skip" ] && continue
    echo ""
    echo "  https://${S_DOMAIN[$i]}"
    [ "${S_MODE[$i]}" = "new" ] && echo "    DB     : ${S_DB_NAME[$i]} / ${S_DB_USER[$i]} / ${S_DB_PASS[$i]}"
    echo "    Restart: supervisorctl restart \$(supervisorctl status | awk '{print \$1}' | grep '_${S_SLUG[$i]}\$' | tr '\\n' ' ')"
    echo "    Remove : $0 --remove ${S_SLUG[$i]}"
done
echo ""
echo "  Credentials appended to: $CRED_FILE"
[ "$SSL_MODE" = "cloudflare" ] && echo "  Cloudflare: set SSL mode to Full (Strict)."
echo "  List sites: $0 --list"
echo "=============================================="

exit $HEALTH_FAIL
