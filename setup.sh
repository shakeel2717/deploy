#!/bin/bash
set -e

echo "=============================================="
echo "  Laravel Multi-Site Setup Wizard"
echo "=============================================="
echo ""

# ---- How many sites? ----
while true; do
    echo "How many sites on this server? (1-5):"
    read SITE_COUNT
    if [[ "$SITE_COUNT" =~ ^[1-5]$ ]]; then break; fi
    echo "Please enter a number between 1 and 5."
done

# ---- Per-site arrays ----
declare -a S_DOMAIN S_SITE_NAME S_REPO S_REPO_AUTH S_DB_NAME S_DB_USER S_DB_PASS S_APP_DIR

for i in $(seq 1 $SITE_COUNT); do
    echo ""
    echo "--- Site $i of $SITE_COUNT ---"

    echo "Enter domain for site $i (e.g. boss.example.com):"
    read S_DOMAIN[$i]

    # Extract site name from first part of domain (boss.alqaswadev.com → boss)
    S_SITE_NAME[$i]=$(echo "${S_DOMAIN[$i]}" | cut -d'.' -f1)
    S_APP_DIR[$i]="/var/www/${S_SITE_NAME[$i]}"

    echo "Enter Git repo URL for site $i:"
    read S_REPO[$i]

    echo "Is this a private repo? (y/n):"
    read PRIVATE
    if [ "$PRIVATE" = "y" ]; then
        echo "Git username:"
        read GIT_USER
        echo "Git token:"
        read GIT_TOKEN
        REPO_PATH="${S_REPO[$i]#https://}"
        S_REPO_AUTH[$i]="https://${GIT_USER}:${GIT_TOKEN}@${REPO_PATH}"
    else
        S_REPO_AUTH[$i]="${S_REPO[$i]}"
    fi

    DEFAULT_DB="${S_SITE_NAME[$i]}_db"
    echo "Database name (default: ${DEFAULT_DB}):"
    read DB_NAME_INPUT
    S_DB_NAME[$i]="${DB_NAME_INPUT:-$DEFAULT_DB}"

    DEFAULT_USER="${S_SITE_NAME[$i]}_user"
    echo "Database user (default: ${DEFAULT_USER}):"
    read DB_USER_INPUT
    S_DB_USER[$i]="${DB_USER_INPUT:-$DEFAULT_USER}"

    echo "Database password (leave blank to auto-generate):"
    read DB_PASS_INPUT
    if [ -z "$DB_PASS_INPUT" ]; then
        S_DB_PASS[$i]=$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 16 | head -n 1)
    else
        S_DB_PASS[$i]="$DB_PASS_INPUT"
    fi
done

# ---- Shared options ----
echo ""
echo "--- Shared Server Options ---"

echo "PHP version - 8.3 or 8.4 (default: 8.3):"
read PHP_VER
PHP_VER=${PHP_VER:-8.3}

echo "Install Laravel Octane? (y/n):"
read OCTANE
if [ "$OCTANE" = "y" ]; then
    echo "Octane server - roadrunner or swoole (default: roadrunner):"
    read OCTANE_SERVER
    OCTANE_SERVER=${OCTANE_SERVER:-roadrunner}
fi

echo "Install Laravel Horizon? (y/n):"
read HORIZON

echo "Install Laravel Reverb WebSockets? (y/n):"
read REVERB

echo "Install Laravel Scheduler? (y/n):"
read SCHEDULER

echo "Install Google Chrome for Spatie Browsershot? (y/n):"
read CHROME

echo "SSL type - cloudflare, letsencrypt, or none (default: cloudflare):"
read SSL_MODE
SSL_MODE=${SSL_MODE:-cloudflare}

APP_USER="larasail"
SSL_CERT="/etc/ssl/certs/cloudflare-origin.pem"
SSL_KEY="/etc/ssl/private/cloudflare-origin.key"

# ---- Summary ----
echo ""
echo "=============================================="
echo "  Summary"
echo "=============================================="
echo "  PHP         : $PHP_VER"
echo "  Octane      : $OCTANE ${OCTANE_SERVER:-}"
echo "  Horizon     : $HORIZON | Reverb: $REVERB | Scheduler: $SCHEDULER | Chrome: $CHROME"
echo "  SSL         : $SSL_MODE"
echo ""
for i in $(seq 1 $SITE_COUNT); do
    OCTANE_PORT=$((8000 + i - 1))
    REVERB_PORT=$((8080 + i - 1))
    echo "  Site $i:"
    echo "    Domain  : ${S_DOMAIN[$i]}"
    echo "    Dir     : ${S_APP_DIR[$i]}"
    echo "    DB      : ${S_DB_NAME[$i]} / ${S_DB_USER[$i]} / ${S_DB_PASS[$i]}"
    [ "$OCTANE" = "y" ] && echo "    Octane  : port $OCTANE_PORT"
    [ "$REVERB" = "y" ] && echo "    Reverb  : port $REVERB_PORT"
done
echo "=============================================="
echo ""
echo "Start installation? (y/n):"
read CONFIRM
[ "$CONFIRM" != "y" ] && echo "Aborted." && exit 1

# ==============================================================
# SYSTEM INSTALL (once)
# ==============================================================
echo "[1/5] System packages..."
export DEBIAN_FRONTEND=noninteractive
apt update && apt upgrade -y -o Dpkg::Options::="--force-confold" -o Dpkg::Options::="--force-confdef"
apt install -y curl git unzip zip wget gnupg ca-certificates software-properties-common acl net-tools ufw

if ! id "$APP_USER" &>/dev/null; then
    adduser --disabled-password --gecos "" $APP_USER
    usermod -aG www-data $APP_USER
    usermod -aG sudo $APP_USER
fi

echo "[2/5] PHP ${PHP_VER}..."
add-apt-repository ppa:ondrej/php -y
apt update
apt install -y php${PHP_VER} php${PHP_VER}-fpm php${PHP_VER}-cli php${PHP_VER}-mbstring \
    php${PHP_VER}-xml php${PHP_VER}-bcmath php${PHP_VER}-curl php${PHP_VER}-zip \
    php${PHP_VER}-gd php${PHP_VER}-intl php${PHP_VER}-mysql php${PHP_VER}-redis \
    php${PHP_VER}-tokenizer php${PHP_VER}-fileinfo php${PHP_VER}-sockets
[ "$OCTANE_SERVER" = "swoole" ] && apt install -y php${PHP_VER}-swoole

curl -sS https://getcomposer.org/installer | php
mv composer.phar /usr/local/bin/composer
chmod +x /usr/local/bin/composer

curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
apt install -y nodejs

apt install -y nginx && systemctl enable nginx && systemctl start nginx

echo "[3/5] MySQL + Redis..."
apt install -y mysql-server && systemctl enable mysql && systemctl start mysql
apt install -y redis-server && systemctl enable redis-server && systemctl start redis-server

if [ ! -f /swapfile ]; then
    fallocate -l 2G /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile
    echo '/swapfile none swap sw 0 0' >> /etc/fstab
    echo 'vm.swappiness=10' >> /etc/sysctl.conf && sysctl -p
fi

apt install -y supervisor && systemctl enable supervisor && systemctl start supervisor

if [ "$CHROME" = "y" ]; then
    apt install -y fonts-liberation libatk-bridge2.0-0 libatk1.0-0 libcairo2 libcups2 \
        libdbus-1-3 libgbm1 libgtk-3-0 libnspr4 libnss3 libpango-1.0-0 libxcomposite1 \
        libxdamage1 libxrandr2 xdg-utils libasound2t64 libx11-xcb1 libxss1
    wget -q https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb
    apt install -y ./google-chrome-stable_current_amd64.deb
    rm -f google-chrome-stable_current_amd64.deb
    sysctl -w kernel.apparmor_restrict_unprivileged_userns=0
    grep -qxF 'kernel.apparmor_restrict_unprivileged_userns = 0' /etc/sysctl.conf \
        || echo "kernel.apparmor_restrict_unprivileged_userns = 0" >> /etc/sysctl.conf
    sysctl -p
    mkdir -p /var/www/.cache/puppeteer
    chown -R www-data:www-data /var/www/.cache
fi

# ==============================================================
# PER-SITE SETUP
# ==============================================================
echo "[4/5] Setting up sites..."
rm -f /etc/nginx/sites-enabled/default

for i in $(seq 1 $SITE_COUNT); do
    DOMAIN="${S_DOMAIN[$i]}"
    REPO_AUTH="${S_REPO_AUTH[$i]}"
    DB_NAME="${S_DB_NAME[$i]}"
    DB_USER="${S_DB_USER[$i]}"
    DB_PASS="${S_DB_PASS[$i]}"
    APP_DIR="${S_APP_DIR[$i]}"
    OCTANE_PORT=$((8000 + i - 1))
    REVERB_PORT=$((8080 + i - 1))
    SITE_SLUG="${S_SITE_NAME[$i]}"

    echo ""
    echo ">>> Setting up ${DOMAIN} in ${APP_DIR}..."

    # MySQL
    mysql -e "CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
    mysql -e "CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';"
    mysql -e "GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'localhost';"
    mysql -e "FLUSH PRIVILEGES;"

    # Clone
    mkdir -p /var/www
    if [ -d "${APP_DIR}/.git" ]; then
        cd $APP_DIR && git pull
    else
        git clone "$REPO_AUTH" "$APP_DIR"
    fi
    git config --global --add safe.directory $APP_DIR
    chown -R $APP_USER:www-data $APP_DIR

    # .env
    cd $APP_DIR
    if [ ! -f ".env" ]; then
        cp .env.example .env
        sed -i "s|APP_URL=.*|APP_URL=https://${DOMAIN}|" .env
        sed -i "s|ASSET_URL=.*|ASSET_URL=https://${DOMAIN}|" .env
        sed -i "s/DB_DATABASE=.*/DB_DATABASE=${DB_NAME}/" .env
        sed -i "s/DB_USERNAME=.*/DB_USERNAME=${DB_USER}/" .env
        sed -i "s/DB_PASSWORD=.*/DB_PASSWORD=${DB_PASS}/" .env
        sed -i "s/APP_ENV=.*/APP_ENV=production/" .env
        sed -i "s/APP_DEBUG=.*/APP_DEBUG=false/" .env
        sed -i "s/OCTANE_SERVER=.*/OCTANE_SERVER=${OCTANE_SERVER:-roadrunner}/" .env
        sed -i "s/QUEUE_CONNECTION=.*/QUEUE_CONNECTION=redis/" .env
        if [ "$REVERB" = "y" ]; then
            sed -i "s|VITE_REVERB_HOST=.*|VITE_REVERB_HOST=${DOMAIN}|" .env
            sed -i "s|REVERB_ALLOWED_ORIGINS=.*|REVERB_ALLOWED_ORIGINS=https://${DOMAIN}|" .env
        fi
    fi

    # Dependencies
    sudo -u $APP_USER composer install --no-dev --optimize-autoloader
    sudo -u $APP_USER npm install
    sudo -u $APP_USER npm run build 2>/dev/null || echo "npm build skipped"
    php artisan key:generate --force
    php artisan migrate --force
    php artisan storage:link

    # Octane
    if [ "$OCTANE" = "y" ]; then
        sudo -u $APP_USER composer require laravel/octane 2>/dev/null || true
        sudo -u $APP_USER php artisan octane:install --server=$OCTANE_SERVER --no-interaction 2>/dev/null || true
        if [ "$OCTANE_SERVER" = "roadrunner" ] && [ ! -f "${APP_DIR}/rr" ]; then
            cd $APP_DIR && sudo -u $APP_USER ./vendor/bin/rr get-binary 2>/dev/null || true
        fi
        touch ${APP_DIR}/.rr.yaml
        chown www-data:www-data ${APP_DIR}/.rr.yaml
        chmod 664 ${APP_DIR}/.rr.yaml
    fi

    # Reverb
    if [ "$REVERB" = "y" ]; then
        sudo -u $APP_USER composer require laravel/reverb 2>/dev/null || true
        sudo -u $APP_USER php artisan reverb:install --no-interaction 2>/dev/null || true
    fi

    # Chrome cache per-site
    if [ "$CHROME" = "y" ]; then
        sudo -u www-data PUPPETEER_CACHE_DIR=/var/www/.cache/puppeteer \
            npx --prefix $APP_DIR puppeteer browsers install chrome-headless-shell
        sudo -u www-data PUPPETEER_CACHE_DIR=/var/www/.cache/puppeteer \
            npx --prefix $APP_DIR puppeteer browsers install chrome
        chmod -R 755 /var/www/.cache/puppeteer
    fi

    # Permissions
    chown -R www-data:www-data $APP_DIR
    chmod -R 775 ${APP_DIR}/storage ${APP_DIR}/bootstrap/cache
    setfacl -R -m u:$APP_USER:rwX $APP_DIR
    setfacl -R -d -m u:$APP_USER:rwX $APP_DIR

    # Supervisor: Octane
    if [ "$OCTANE" = "y" ]; then
        cat > /etc/supervisor/conf.d/octane_${SITE_SLUG}.conf << SUPEOF
[program:octane_${SITE_SLUG}]
process_name=%(program_name)s
command=/usr/bin/php ${APP_DIR}/artisan octane:start --server=${OCTANE_SERVER} --host=127.0.0.1 --port=${OCTANE_PORT}
autostart=true
autorestart=true
user=www-data
redirect_stderr=true
stdout_logfile=${APP_DIR}/storage/logs/octane.log
stopwaitsecs=10
SUPEOF
    fi

    # Supervisor: Horizon
    if [ "$HORIZON" = "y" ]; then
        cat > /etc/supervisor/conf.d/horizon_${SITE_SLUG}.conf << SUPEOF
[program:horizon_${SITE_SLUG}]
process_name=%(program_name)s
command=/usr/bin/php ${APP_DIR}/artisan horizon
autostart=true
autorestart=true
user=www-data
redirect_stderr=true
stdout_logfile=${APP_DIR}/storage/logs/horizon.log
stopwaitsecs=3600
SUPEOF
    fi

    # Supervisor: Scheduler
    if [ "$SCHEDULER" = "y" ]; then
        cat > /etc/supervisor/conf.d/scheduler_${SITE_SLUG}.conf << SUPEOF
[program:scheduler_${SITE_SLUG}]
process_name=%(program_name)s
command=/usr/bin/php ${APP_DIR}/artisan schedule:work --no-interaction
directory=${APP_DIR}
autostart=true
autorestart=true
user=www-data
redirect_stderr=true
stdout_logfile=${APP_DIR}/storage/logs/scheduler.log
SUPEOF
    fi

    # Supervisor: Reverb
    if [ "$REVERB" = "y" ]; then
        cat > /etc/supervisor/conf.d/reverb_${SITE_SLUG}.conf << SUPEOF
[program:reverb_${SITE_SLUG}]
process_name=%(program_name)s
command=/usr/bin/php ${APP_DIR}/artisan reverb:start --host=127.0.0.1 --port=${REVERB_PORT}
autostart=true
autorestart=true
user=www-data
redirect_stderr=true
stdout_logfile=${APP_DIR}/storage/logs/reverb.log
stopwaitsecs=3600
SUPEOF
    fi

    # ---- Build Nginx config ----
    # Reverb WebSocket block (only if enabled)
    if [ "$REVERB" = "y" ]; then
        REVERB_BLOCK="
    location /app {
        proxy_http_version 1.1;
        proxy_set_header Host \$http_host;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection Upgrade;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_pass http://127.0.0.1:${REVERB_PORT};
    }"
    else
        REVERB_BLOCK=""
    fi

    # PHP backend block — Octane proxy OR PHP-FPM
    if [ "$OCTANE" = "y" ]; then
        PHP_BACKEND="
    # Static assets: serve from disk if the file exists, otherwise fall through to Octane.
    # This is critical for dynamic .js routes like /livewire/livewire.min.js.
    location ~* \.(js|css|png|jpg|jpeg|gif|ico|svg|woff|woff2|ttf|eot|map|webp)\$ {
        expires max;
        log_not_found off;
        try_files \$uri @octane;
    }

    location / {
        try_files \$uri @octane;
    }

    location @octane {
        proxy_http_version 1.1;
        proxy_set_header Host \$http_host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_pass http://127.0.0.1:${OCTANE_PORT};
    }"
    else
        PHP_BACKEND="
    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ \.php\$ {
        fastcgi_pass unix:/var/run/php/php${PHP_VER}-fpm.sock;
        fastcgi_param SCRIPT_FILENAME \$realpath_root\$fastcgi_script_name;
        include fastcgi_params;
    }"
    fi

    # Write nginx config (SSL or plain HTTP)
    if [ "$SSL_MODE" = "cloudflare" ] && [ -f "$SSL_CERT" ] && [ -f "$SSL_KEY" ]; then
        cat > /etc/nginx/sites-available/${SITE_SLUG}_${DOMAIN}.conf << NGXEOF
server {
    listen 80;
    server_name ${DOMAIN} www.${DOMAIN};
    return 301 https://\$host\$request_uri;
}
server {
    listen 443 ssl;
    server_name ${DOMAIN} www.${DOMAIN};
    root ${APP_DIR}/public;
    ssl_certificate     ${SSL_CERT};
    ssl_certificate_key ${SSL_KEY};
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;
    add_header X-Frame-Options SAMEORIGIN;
    add_header X-Content-Type-Options nosniff;
    index index.php;
    charset utf-8;
${REVERB_BLOCK}
${PHP_BACKEND}
    location = /favicon.ico { access_log off; log_not_found off; }
    location = /robots.txt  { access_log off; log_not_found off; }
}
NGXEOF
    else
        # HTTP only (Let's Encrypt will upgrade it, or SSL=none)
        cat > /etc/nginx/sites-available/${SITE_SLUG}_${DOMAIN}.conf << NGXEOF
server {
    listen 80;
    server_name ${DOMAIN} www.${DOMAIN};
    root ${APP_DIR}/public;
    index index.php;
    charset utf-8;
    add_header X-Frame-Options SAMEORIGIN;
    add_header X-Content-Type-Options nosniff;
${REVERB_BLOCK}
${PHP_BACKEND}
    location = /favicon.ico { access_log off; log_not_found off; }
    location = /robots.txt  { access_log off; log_not_found off; }
}
NGXEOF
        if [ "$SSL_MODE" = "letsencrypt" ]; then
            apt install -y certbot python3-certbot-nginx
            certbot --nginx -d $DOMAIN -d www.$DOMAIN --non-interactive --agree-tos -m admin@$DOMAIN
        fi
    fi

    ln -sf /etc/nginx/sites-available/${SITE_SLUG}_${DOMAIN}.conf \
           /etc/nginx/sites-enabled/${SITE_SLUG}_${DOMAIN}.conf

    # Laravel cache
    cd $APP_DIR
    php artisan config:cache
    php artisan route:cache
    php artisan view:cache

    echo ">>> Site ${DOMAIN} done."
done

# ==============================================================
# CROSS-DB MYSQL GRANTS (multi-site only)
# ==============================================================
if [ "$SITE_COUNT" -gt 1 ]; then
    echo ""
    echo "Granting cross-database SELECT permissions..."
    for i in $(seq 1 $SITE_COUNT); do
        for j in $(seq 1 $SITE_COUNT); do
            if [ "$i" != "$j" ]; then
                mysql -e "GRANT SELECT ON \`${S_DB_NAME[$j]}\`.* TO '${S_DB_USER[$i]}'@'localhost';"
                echo "  Granted: ${S_DB_USER[$i]} -> SELECT on ${S_DB_NAME[$j]}"
            fi
        done
    done
    mysql -e "FLUSH PRIVILEGES;"
    echo "Cross-DB grants done."
fi

# ==============================================================
# FINALIZE
# ==============================================================
echo "[5/5] Starting services..."
supervisorctl reread
supervisorctl update
supervisorctl start all 2>/dev/null || true

nginx -t && systemctl reload nginx

ufw allow OpenSSH
ufw allow 'Nginx Full'
ufw --force enable

# ==============================================================
# DONE
# ==============================================================
echo ""
echo "=============================================="
echo "  DONE!"
echo "=============================================="
for i in $(seq 1 $SITE_COUNT); do
    OCTANE_PORT=$((8000 + i - 1))
    REVERB_PORT=$((8080 + i - 1))
    echo ""
    echo "  Site $i: https://${S_DOMAIN[$i]}"
    echo "    DB Name : ${S_DB_NAME[$i]}"
    echo "    DB User : ${S_DB_USER[$i]}"
    echo "    DB Pass : ${S_DB_PASS[$i]}   <-- SAVE THIS!"
    echo "    App Dir : ${S_APP_DIR[$i]}"
    [ "$OCTANE"    = "y" ] && echo "    Octane  : port $OCTANE_PORT"
    [ "$REVERB"    = "y" ] && echo "    Reverb  : port $REVERB_PORT"
done
echo ""
echo "  Supervisor commands:"
for i in $(seq 1 $SITE_COUNT); do
    SLUG="${S_SITE_NAME[$i]}"
    [ "$OCTANE"    = "y" ] && echo "    supervisorctl restart octane_${SLUG}"
    [ "$HORIZON"   = "y" ] && echo "    supervisorctl restart horizon_${SLUG}"
    [ "$REVERB"    = "y" ] && echo "    supervisorctl restart reverb_${SLUG}"
    [ "$SCHEDULER" = "y" ] && echo "    supervisorctl restart scheduler_${SLUG}"
done
echo ""
if [ "$SSL_MODE" = "cloudflare" ] && [ ! -f "$SSL_CERT" ]; then
    echo "  CLOUDFLARE SSL NEXT STEPS:"
    echo "  1. nano $SSL_CERT   (paste certificate)"
    echo "  2. nano $SSL_KEY    (paste private key)"
    echo "  3. nginx -t && systemctl reload nginx"
    echo "  4. Set Cloudflare SSL mode to Full (Strict)"
fi
echo "=============================================="
