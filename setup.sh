#!/bin/bash
###############################################################################
#  Laravel Multi-Site Setup Wizard  —  idempotent / safe to re-run
#  Ubuntu 22.04 / 24.04  •  Laravel 12  •  Octane + Horizon + Reverb + Scheduler
#
#  Run again any time to ADD a new site. Existing sites are never touched.
###############################################################################
set -e

APP_USER="larasail"
WEB_ROOT="/var/www"
STATE_DIR="/etc/laravel-multisite"
SITES_DIR="$STATE_DIR/sites"
PROVISION_MARKER="$STATE_DIR/.provisioned"
CRED_FILE="/root/laravel-sites-credentials.txt"

[ "$EUID" -eq 0 ] || { echo "ERROR: run as root (sudo -i)"; exit 1; }
mkdir -p "$SITES_DIR"

###############################################################################
#  Helpers
###############################################################################

# env_set KEY VALUE FILE  — updates the key, or appends it if missing
env_set() {
    local k="$1" v="$2" f="$3"
    if grep -q "^${k}=" "$f"; then
        sed -i "s|^${k}=.*|${k}=${v}|" "$f"
    else
        printf '%s=%s\n' "$k" "$v" >> "$f"
    fi
}

rand() { tr -dc "$1" < /dev/urandom | head -c "$2"; echo; }

as_app()  { sudo -u "$APP_USER" -H env HOME="/home/$APP_USER" "$@"; }
as_web()  { sudo -u www-data   -H env HOME="/var/www" "$@"; }

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
    REDIS_IN_USE="$REDIS_IN_USE $d"
    ALLOC_REDIS="$d"
}

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

# Ports already claimed by supervisor programs OR currently listening
PORTS_IN_USE="$(grep -rho -- '--port=[0-9]*' /etc/supervisor/conf.d/ 2>/dev/null | cut -d= -f2 | tr '\n' ' ' || true)"
PORTS_IN_USE="$PORTS_IN_USE $(ss -lntH 2>/dev/null | awk '{print $4}' | sed 's/.*://' | tr '\n' ' ' || true)"

# Redis DB indexes already claimed by existing .env files
REDIS_IN_USE="$(grep -h -E '^(REDIS_DB|REDIS_CACHE_DB)=' "$WEB_ROOT"/*/.env 2>/dev/null | cut -d= -f2 | tr -d '\r' | tr '\n' ' ' || true)"

if [ ${#EXISTING_SITES[@]} -gt 0 ]; then
    echo "  Existing sites detected (${#EXISTING_SITES[@]}):"
    for s in "${EXISTING_SITES[@]}"; do
        SD=$(grep '^APP_URL=' "$WEB_ROOT/$s/.env" 2>/dev/null | cut -d= -f2- | tr -d '\r')
        echo "    - $s  ${SD}"
    done
    echo "  Ports in use     : ${PORTS_IN_USE:-none}"
    echo "  Redis DBs in use : ${REDIS_IN_USE:-none}"
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

echo ""
read -rp "Use the SAME git repository for all sites? [Y/n]: " SHARED_REPO_ANS
SHARED_REPO_ANS=${SHARED_REPO_ANS:-y}
if [[ "$SHARED_REPO_ANS" =~ ^[Yy]$ ]]; then
    read -rp "Git repo URL: " SHARED_REPO_URL
    read -rp "Private repo? [Y/n]: " SHARED_PRIVATE
    SHARED_PRIVATE=${SHARED_PRIVATE:-y}
    if [[ "$SHARED_PRIVATE" =~ ^[Yy]$ ]]; then
        read -rp "Git username: " GIT_USER
        read -rsp "Git token: " GIT_TOKEN; echo ""
    fi
fi

declare -a S_DOMAIN S_SLUG S_REPO S_DB_NAME S_DB_USER S_DB_PASS S_DIR S_MODE

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

    if [ -f "${S_DIR[$i]}/artisan" ]; then
        echo "  !! ${S_DIR[$i]} already exists."
        read -rp "  Redeploy it instead (git pull + composer + migrate, .env & DB untouched)? [y/N]: " RD
        if [[ "${RD:-n}" =~ ^[Yy]$ ]]; then
            S_MODE[$i]="redeploy"
        else
            echo "  Skipping this site."
            S_MODE[$i]="skip"
            continue
        fi
    fi

    # Repo
    if [[ "$SHARED_REPO_ANS" =~ ^[Yy]$ ]]; then
        if [[ "$SHARED_PRIVATE" =~ ^[Yy]$ ]]; then
            S_REPO[$i]="https://${GIT_USER}:${GIT_TOKEN}@${SHARED_REPO_URL#https://}"
        else
            S_REPO[$i]="$SHARED_REPO_URL"
        fi
    else
        read -rp "Git repo URL for this site: " SITE_REPO
        read -rp "Private repo? [Y/n]: " SITE_PRIVATE
        SITE_PRIVATE=${SITE_PRIVATE:-y}
        if [[ "$SITE_PRIVATE" =~ ^[Yy]$ ]]; then
            read -rp "Git username: " SGU
            read -rsp "Git token: " SGT; echo ""
            S_REPO[$i]="https://${SGU}:${SGT}@${SITE_REPO#https://}"
        else
            S_REPO[$i]="$SITE_REPO"
        fi
    fi

    if [ "${S_MODE[$i]}" = "new" ]; then
        read -rp "Database name [${S_SLUG[$i]}_db]: " V; S_DB_NAME[$i]="${V:-${S_SLUG[$i]}_db}"
        read -rp "Database user [${S_SLUG[$i]}_user]: " V; S_DB_USER[$i]="${V:-${S_SLUG[$i]}_user}"
        S_DB_PASS[$i]=$(rand 'a-zA-Z0-9' 20)
    fi
done

###############################################################################
#  Shared options
###############################################################################
echo ""
echo "--- Server Options ---"
read -rp "PHP version [8.3]: " PHP_VER; PHP_VER=${PHP_VER:-8.3}

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

RUN_SYSTEM=y
if [ -f "$PROVISION_MARKER" ]; then
    echo ""
    echo "  This server is already provisioned."
    read -rp "  Re-run system package install / apt upgrade? (not needed) [y/N]: " V
    [[ "${V:-n}" =~ ^[Yy]$ ]] && RUN_SYSTEM=y || RUN_SYSTEM=n
fi

SSL_CERT="/etc/ssl/certs/cloudflare-origin.pem"
SSL_KEY="/etc/ssl/private/cloudflare-origin.key"
if [ "$SSL_MODE" = "cloudflare" ] && { [ ! -f "$SSL_CERT" ] || [ ! -f "$SSL_KEY" ]; }; then
    echo ""
    echo "  Cloudflare origin cert not found. Create it now:"
    echo "    Cloudflare -> SSL/TLS -> Origin Server -> Create Certificate"
    echo "    nano $SSL_CERT"
    echo "    nano $SSL_KEY"
    read -rp "  Press ENTER when done..." _
    { [ -f "$SSL_CERT" ] && [ -f "$SSL_KEY" ]; } || { echo "ERROR: cert files missing."; exit 1; }
fi

###############################################################################
#  Pre-allocate ports / redis DBs, then show summary
###############################################################################
declare -a S_OPORT S_RPORT S_RDB S_RCDB
for i in $(seq 1 "$SITE_COUNT"); do
    [ "${S_MODE[$i]}" = "skip" ] && continue
    if [ "${S_MODE[$i]}" = "redeploy" ]; then
        S_OPORT[$i]=$(grep -ho -- '--port=[0-9]*' "/etc/supervisor/conf.d/octane_${S_SLUG[$i]}.conf" 2>/dev/null | cut -d= -f2 || true)
        S_RPORT[$i]=$(grep -ho -- '--port=[0-9]*' "/etc/supervisor/conf.d/reverb_${S_SLUG[$i]}.conf" 2>/dev/null | cut -d= -f2 || true)
        continue
    fi
    alloc_port 8000; S_OPORT[$i]=$ALLOC_PORT
    alloc_port 8080; S_RPORT[$i]=$ALLOC_PORT
    alloc_redis;     S_RDB[$i]=$ALLOC_REDIS
    alloc_redis;     S_RCDB[$i]=$ALLOC_REDIS
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
    [ "${S_MODE[$i]}" = "new" ] && echo "    Redis : DB ${S_RDB[$i]} / cache ${S_RCDB[$i]}"
    [ "$OCTANE" = "y" ] && echo "    Octane: port ${S_OPORT[$i]}"
    [ "$REVERB" = "y" ] && echo "    Reverb: port ${S_RPORT[$i]}"
done
echo "=============================================="
read -rp "Start installation? [Y/n]: " V
[[ "${V:-y}" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 1; }

###############################################################################
#  [1/5] System packages
###############################################################################
if [ "$RUN_SYSTEM" = "y" ]; then
    echo "[1/5] System packages..."
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

    echo "[2/5] PHP ${PHP_VER}..."
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
    echo "[1/5] System already provisioned — skipping apt (no downtime for live sites)."
fi

###############################################################################
#  [3/5] Per-site setup
###############################################################################
echo "[3/5] Setting up sites..."

for i in $(seq 1 "$SITE_COUNT"); do
    [ "${S_MODE[$i]}" = "skip" ] && continue

    DOMAIN="${S_DOMAIN[$i]}"; SLUG="${S_SLUG[$i]}"; APP_DIR="${S_DIR[$i]}"
    OPORT="${S_OPORT[$i]:-}"; RPORT="${S_RPORT[$i]:-}"

    echo ""
    echo ">>> ${DOMAIN}  (${APP_DIR})"

    # ---------- MySQL (new sites only) ----------
    if [ "${S_MODE[$i]}" = "new" ]; then
        mysql -e "CREATE DATABASE IF NOT EXISTS \`${S_DB_NAME[$i]}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
        mysql -e "CREATE USER IF NOT EXISTS '${S_DB_USER[$i]}'@'localhost' IDENTIFIED BY '${S_DB_PASS[$i]}';"
        mysql -e "ALTER USER '${S_DB_USER[$i]}'@'localhost' IDENTIFIED BY '${S_DB_PASS[$i]}';"
        mysql -e "GRANT ALL PRIVILEGES ON \`${S_DB_NAME[$i]}\`.* TO '${S_DB_USER[$i]}'@'localhost';"
        mysql -e "FLUSH PRIVILEGES;"
    fi

    # ---------- Code ----------
    mkdir -p "$WEB_ROOT"
    git config --global --get-all safe.directory | grep -qx "$APP_DIR" \
        || git config --global --add safe.directory "$APP_DIR"

    if [ -d "${APP_DIR}/.git" ]; then
        cd "$APP_DIR" && git pull
    else
        git clone "${S_REPO[$i]}" "$APP_DIR"
    fi
    chown -R "$APP_USER":www-data "$APP_DIR"
    cd "$APP_DIR"

    # ---------- .env ----------
    if [ ! -f .env ]; then
        cp .env.example .env
        chown "$APP_USER":www-data .env
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
        # --- isolation between sites sharing one Redis instance ---
        env_set REDIS_CLIENT          phpredis                 .env
        env_set REDIS_DB              "${S_RDB[$i]}"           .env
        env_set REDIS_CACHE_DB        "${S_RCDB[$i]}"          .env
        env_set REDIS_PREFIX          "${SLUG}_db_"            .env
        env_set CACHE_PREFIX          "${SLUG}_cache_"         .env
        env_set HORIZON_PREFIX        "${SLUG}_horizon:"       .env
        [ "$OCTANE" = "y" ] && env_set OCTANE_SERVER "${OCTANE_SERVER}" .env

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
    fi

    # ---------- Dependencies ----------
    as_app composer install --no-dev --optimize-autoloader --no-interaction
    [ "$OCTANE" = "y" ]  && as_app composer require laravel/octane  --no-interaction || true
    [ "$HORIZON" = "y" ] && as_app composer require laravel/horizon --no-interaction || true
    [ "$REVERB" = "y" ]  && as_app composer require laravel/reverb  --no-interaction || true

    if [ -f package.json ]; then
        if [ -f package-lock.json ]; then as_app npm ci --no-audit --no-fund
        else as_app npm install --no-audit --no-fund; fi
        as_app npm run build || echo "  npm build skipped"
    fi

    # ---------- Ownership BEFORE artisan, so no root-owned cache files ----------
    chown -R www-data:www-data "$APP_DIR"
    chmod -R 775 storage bootstrap/cache
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
    [ "$REVERB" = "y" ]  && { as_web php${PHP_VER} artisan reverb:install --no-interaction || true; }

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
    write_prog() { # write_prog NAME COMMAND LOG STOPWAIT
        cat > "/etc/supervisor/conf.d/${1}_${SLUG}.conf" << SUPEOF
[program:${1}_${SLUG}]
process_name=%(program_name)s
directory=${APP_DIR}
command=${2}
autostart=true
autorestart=true
stopasgroup=true
killasgroup=true
user=www-data
environment=HOME="/var/www",USER="www-data"
redirect_stderr=true
stdout_logfile=${APP_DIR}/storage/logs/${1}.log
stopwaitsecs=${4}
SUPEOF
    }

    [ "$OCTANE" = "y" ] && write_prog octane \
        "/usr/bin/php${PHP_VER} ${APP_DIR}/artisan octane:start --server=${OCTANE_SERVER} --host=127.0.0.1 --port=${OPORT}" "" 10
    [ "$HORIZON" = "y" ] && write_prog horizon \
        "/usr/bin/php${PHP_VER} ${APP_DIR}/artisan horizon" "" 3600
    [ "$SCHEDULER" = "y" ] && write_prog scheduler \
        "/usr/bin/php${PHP_VER} ${APP_DIR}/artisan schedule:work --no-interaction" "" 60
    [ "$REVERB" = "y" ] && write_prog reverb \
        "/usr/bin/php${PHP_VER} ${APP_DIR}/artisan reverb:start --host=127.0.0.1 --port=${RPORT}" "" 3600

    ###########################################################################
    #  Nginx
    ###########################################################################
    NGINX_CONF="/etc/nginx/sites-available/${SLUG}_${DOMAIN}.conf"
    if [ ! -f "$NGINX_CONF" ]; then

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
            cat > "$NGINX_CONF" << NGXEOF
server {
    listen 80;
    server_name ${DOMAIN} www.${DOMAIN};
    return 301 https://\$host\$request_uri;
}
server {
    listen 443 ssl;
    http2 on;
    server_name ${DOMAIN} www.${DOMAIN};
    ssl_certificate     ${SSL_CERT};
    ssl_certificate_key ${SSL_KEY};
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;
${COMMON}
}
NGXEOF
        else
            cat > "$NGINX_CONF" << NGXEOF
server {
    listen 80;
    server_name ${DOMAIN} www.${DOMAIN};
${COMMON}
}
NGXEOF
        fi

        ln -sf "$NGINX_CONF" "/etc/nginx/sites-enabled/${SLUG}_${DOMAIN}.conf"

        if [ "$SSL_MODE" = "letsencrypt" ]; then
            apt install -y certbot python3-certbot-nginx
            nginx -t && systemctl reload nginx
            certbot --nginx -d "$DOMAIN" -d "www.$DOMAIN" --non-interactive --agree-tos -m "admin@${DOMAIN}"
        fi
    else
        echo "  Nginx config exists — skipping"
    fi

    # ---------- Registry ----------
    cat > "${SITES_DIR}/${SLUG}.conf" << REGEOF
DOMAIN=${DOMAIN}
DIR=${APP_DIR}
OCTANE_PORT=${OPORT}
REVERB_PORT=${RPORT}
REDIS_DB=${S_RDB[$i]:-}
REDIS_CACHE_DB=${S_RCDB[$i]:-}
DB_NAME=${S_DB_NAME[$i]:-}
DB_USER=${S_DB_USER[$i]:-}
REGEOF

    echo ">>> ${DOMAIN} done."
done

###############################################################################
#  [4/5] Cross-DB grants across ALL sites on the server
###############################################################################
echo "[4/5] Cross-database grants..."
declare -a CDB_NAMES CDB_USERS
for d in "$WEB_ROOT"/*/; do
    [ -f "${d}.env" ] || continue
    N=$(grep '^DB_DATABASE=' "${d}.env" | cut -d= -f2- | tr -d '\r"')
    U=$(grep '^DB_USERNAME=' "${d}.env" | cut -d= -f2- | tr -d '\r"')
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
#  [5/5] Start services
###############################################################################
echo "[5/5] Starting services..."
supervisorctl reread
supervisorctl update
nginx -t && systemctl reload nginx
ufw allow OpenSSH >/dev/null
ufw allow 'Nginx Full' >/dev/null
ufw --force enable >/dev/null

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
        echo "  Redis   : ${S_RDB[$i]} / ${S_RCDB[$i]}"
    done
} >> "$CRED_FILE"
chmod 600 "$CRED_FILE"

echo ""
echo "=============================================="
echo "  DONE!"
echo "=============================================="
for i in $(seq 1 "$SITE_COUNT"); do
    [ "${S_MODE[$i]}" = "skip" ] && continue
    echo ""
    echo "  https://${S_DOMAIN[$i]}"
    [ "${S_MODE[$i]}" = "new" ] && echo "    DB: ${S_DB_NAME[$i]} / ${S_DB_USER[$i]} / ${S_DB_PASS[$i]}"
    echo "    Restart: supervisorctl restart 'octane_${S_SLUG[$i]}' 'horizon_${S_SLUG[$i]}' 'reverb_${S_SLUG[$i]}' 'scheduler_${S_SLUG[$i]}' 2>/dev/null"
done
echo ""
echo "  Credentials appended to: $CRED_FILE"
[ "$SSL_MODE" = "cloudflare" ] && echo "  Cloudflare: set SSL mode to Full (Strict)."
echo "=============================================="
