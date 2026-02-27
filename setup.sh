#!/bin/bash
set -e

echo "=============================================="
echo "  Laravel Setup Wizard"
echo "=============================================="

echo ""
echo "Enter your domain (e.g. example.com):"
read DOMAIN

echo "Enter your Git repo URL (e.g. https://github.com/user/repo):"
read REPO

echo "Is this a private repo? (y/n):"
read PRIVATE

if [ "$PRIVATE" = "y" ]; then
    echo "Enter Git username:"
    read GIT_USER
    echo "Enter Git token:"
    read GIT_TOKEN
    REPO_PATH="${REPO#https://}"
    REPO_AUTH="https://${GIT_USER}:${GIT_TOKEN}@${REPO_PATH}"
else
    REPO_AUTH="$REPO"
fi

echo "Enter database name (default: laravel):"
read DB_NAME
DB_NAME=${DB_NAME:-laravel}

echo "Enter database user (default: laravel):"
read DB_USER
DB_USER=${DB_USER:-laravel}

echo "Enter database password (leave blank to auto-generate):"
read DB_PASS
if [ -z "$DB_PASS" ]; then
    DB_PASS=$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 16 | head -n 1)
fi

echo "Enter PHP version - 8.3 or 8.4 (default: 8.3):"
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
if [ "$REVERB" = "y" ]; then
    REVERB_PORT=8080
fi

echo "Install Laravel Scheduler? (y/n):"
read SCHEDULER

echo "Install Google Chrome for Spatie PDF/Browsershot? (y/n):"
read CHROME

echo "SSL type - cloudflare, letsencrypt, or none (default: cloudflare):"
read SSL_MODE
SSL_MODE=${SSL_MODE:-cloudflare}

APP_USER="larasail"
APP_DIR="/var/www/laravel"
SSL_CERT="/etc/ssl/certs/cloudflare-origin.pem"
SSL_KEY="/etc/ssl/private/cloudflare-origin.key"

echo ""
echo "=============================================="
echo "  Summary"
echo "=============================================="
echo "  Domain      : $DOMAIN"
echo "  Repo        : $REPO"
echo "  PHP         : $PHP_VER"
echo "  Octane      : $OCTANE ${OCTANE_SERVER:-}"
echo "  Horizon     : $HORIZON"
echo "  Reverb      : $REVERB"
echo "  Scheduler   : $SCHEDULER"
echo "  Chrome      : $CHROME"
echo "  SSL         : $SSL_MODE"
echo "  DB Name     : $DB_NAME"
echo "  DB User     : $DB_USER"
echo "  DB Pass     : $DB_PASS"
echo "=============================================="
echo ""
echo "Start installation? (y/n):"
read CONFIRM
if [ "$CONFIRM" != "y" ]; then
    echo "Aborted."
    exit 1
fi

echo "Starting..."

# ---- System update (non-interactive, no SSH config prompt) ----
export DEBIAN_FRONTEND=noninteractive
apt update && apt upgrade -y -o Dpkg::Options::="--force-confold" -o Dpkg::Options::="--force-confdef"
apt install -y curl git unzip zip wget gnupg ca-certificates software-properties-common acl net-tools ufw

# ---- App user ----
if ! id "$APP_USER" &>/dev/null; then
    adduser --disabled-password --gecos "" $APP_USER
    usermod -aG www-data $APP_USER
    usermod -aG sudo $APP_USER
fi

# ---- PHP ----
add-apt-repository ppa:ondrej/php -y
apt update
apt install -y php${PHP_VER} php${PHP_VER}-fpm php${PHP_VER}-cli php${PHP_VER}-mbstring php${PHP_VER}-xml php${PHP_VER}-bcmath php${PHP_VER}-curl php${PHP_VER}-zip php${PHP_VER}-gd php${PHP_VER}-intl php${PHP_VER}-mysql php${PHP_VER}-redis php${PHP_VER}-tokenizer php${PHP_VER}-fileinfo php${PHP_VER}-sockets

if [ "$OCTANE_SERVER" = "swoole" ]; then
    apt install -y php${PHP_VER}-swoole
fi

# ---- Composer ----
curl -sS https://getcomposer.org/installer | php
mv composer.phar /usr/local/bin/composer
chmod +x /usr/local/bin/composer

# ---- Node.js ----
curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
apt install -y nodejs

# ---- Nginx ----
apt install -y nginx
systemctl enable nginx
systemctl start nginx

# ---- MySQL ----
apt install -y mysql-server
systemctl enable mysql
systemctl start mysql
mysql -e "CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
mysql -e "CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';"
mysql -e "GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'localhost';"
mysql -e "FLUSH PRIVILEGES;"

# ---- Redis ----
apt install -y redis-server
systemctl enable redis-server
systemctl start redis-server

# ---- Supervisor ----
apt install -y supervisor
systemctl enable supervisor
systemctl start supervisor

# ---- Clone repo ----
mkdir -p /var/www
if [ -d "$APP_DIR/.git" ]; then
    echo "Repo exists, pulling..."
    cd $APP_DIR && git pull
else
    git clone "$REPO_AUTH" "$APP_DIR"
fi
git config --global --add safe.directory $APP_DIR
chown -R $APP_USER:www-data $APP_DIR

# ---- .env — copy from .env.example then update only dynamic values ----
cd $APP_DIR
if [ ! -f ".env" ]; then
    cp .env.example .env

    # Update dynamic values only — everything else (Reverb, Vite, Mail etc) stays from .env.example
    sed -i "s|APP_URL=.*|APP_URL=https://${DOMAIN}|" .env
    sed -i "s|ASSET_URL=.*|ASSET_URL=https://${DOMAIN}|" .env
    sed -i "s/DB_DATABASE=.*/DB_DATABASE=${DB_NAME}/" .env
    sed -i "s/DB_USERNAME=.*/DB_USERNAME=${DB_USER}/" .env
    sed -i "s/DB_PASSWORD=.*/DB_PASSWORD=${DB_PASS}/" .env
    sed -i "s/APP_ENV=.*/APP_ENV=production/" .env
    sed -i "s/APP_DEBUG=.*/APP_DEBUG=false/" .env
    sed -i "s/OCTANE_SERVER=.*/OCTANE_SERVER=${OCTANE_SERVER:-roadrunner}/" .env

    # Update Reverb/Vite domain to match this server's domain
    if [ "$REVERB" = "y" ]; then
        sed -i "s|VITE_REVERB_HOST=.*|VITE_REVERB_HOST=${DOMAIN}|" .env
        sed -i "s|REVERB_ALLOWED_ORIGINS=.*|REVERB_ALLOWED_ORIGINS=https://${DOMAIN}|" .env
    fi
fi

# ---- Dependencies ----
sudo -u $APP_USER composer install --no-dev --optimize-autoloader
sudo -u $APP_USER npm install
sudo -u $APP_USER npm run build 2>/dev/null || echo "npm build skipped"

php artisan key:generate --force
php artisan migrate --force
php artisan storage:link

# ---- Octane ----
if [ "$OCTANE" = "y" ]; then
    sudo -u $APP_USER composer require laravel/octane 2>/dev/null || true
    sudo -u $APP_USER php artisan octane:install --server=$OCTANE_SERVER --no-interaction 2>/dev/null || true
    if [ "$OCTANE_SERVER" = "roadrunner" ] && [ ! -f "$APP_DIR/rr" ]; then
        cd $APP_DIR && sudo -u $APP_USER ./vendor/bin/rr get-binary 2>/dev/null || true
    fi
    touch $APP_DIR/.rr.yaml
    chown www-data:www-data $APP_DIR/.rr.yaml
    chmod 664 $APP_DIR/.rr.yaml
fi

# ---- Reverb ----
if [ "$REVERB" = "y" ]; then
    sudo -u $APP_USER composer require laravel/reverb 2>/dev/null || true
    sudo -u $APP_USER php artisan reverb:install --no-interaction 2>/dev/null || true
fi

# ---- Chrome + Puppeteer cache (fixes Spatie Browsershot) ----
if [ "$CHROME" = "y" ]; then
    apt install -y fonts-liberation libatk-bridge2.0-0 libatk1.0-0 libcairo2 libcups2 libdbus-1-3 libgbm1 libgtk-3-0 libnspr4 libnss3 libpango-1.0-0 libxcomposite1 libxdamage1 libxrandr2 xdg-utils libasound2t64 libx11-xcb1 libxss1
    wget -q https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb
    apt install -y ./google-chrome-stable_current_amd64.deb
    rm -f google-chrome-stable_current_amd64.deb

    # Chrome sandbox fix for Ubuntu 24.04
    sysctl -w kernel.apparmor_restrict_unprivileged_userns=0
    grep -qxF 'kernel.apparmor_restrict_unprivileged_userns = 0' /etc/sysctl.conf || echo "kernel.apparmor_restrict_unprivileged_userns = 0" >> /etc/sysctl.conf
    sysctl -p

    # Puppeteer browser cache
    mkdir -p /var/www/.cache/puppeteer
    chown -R www-data:www-data /var/www/.cache
    sudo -u www-data PUPPETEER_CACHE_DIR=/var/www/.cache/puppeteer npx --prefix $APP_DIR puppeteer browsers install chrome-headless-shell
    sudo -u www-data PUPPETEER_CACHE_DIR=/var/www/.cache/puppeteer npx --prefix $APP_DIR puppeteer browsers install chrome
    chmod -R 755 /var/www/.cache/puppeteer
fi

# ---- Permissions ----
chown -R www-data:www-data $APP_DIR
chmod -R 775 $APP_DIR/storage $APP_DIR/bootstrap/cache
setfacl -R -m u:$APP_USER:rwX $APP_DIR
setfacl -R -d -m u:$APP_USER:rwX $APP_DIR

# ---- Supervisor - Octane ----
if [ "$OCTANE" = "y" ]; then
cat > /etc/supervisor/conf.d/octane.conf << SUPEOF
[program:octane]
process_name=%(program_name)s
command=/usr/bin/php ${APP_DIR}/artisan octane:start --server=${OCTANE_SERVER} --host=127.0.0.1 --port=8000
autostart=true
autorestart=true
user=www-data
redirect_stderr=true
stdout_logfile=${APP_DIR}/storage/logs/octane.log
stopwaitsecs=10
SUPEOF
fi

# ---- Supervisor - Horizon ----
if [ "$HORIZON" = "y" ]; then
cat > /etc/supervisor/conf.d/horizon.conf << SUPEOF
[program:horizon]
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

# ---- Supervisor - Scheduler ----
if [ "$SCHEDULER" = "y" ]; then
cat > /etc/supervisor/conf.d/scheduler.conf << SUPEOF
[program:scheduler]
process_name=%(program_name)s
command=/bin/bash -c "while true; do /usr/bin/php ${APP_DIR}/artisan schedule:run --verbose --no-interaction & sleep 60; done"
autostart=true
autorestart=true
user=www-data
redirect_stderr=true
stdout_logfile=${APP_DIR}/storage/logs/scheduler.log
SUPEOF
fi

# ---- Supervisor - Reverb ----
if [ "$REVERB" = "y" ]; then
cat > /etc/supervisor/conf.d/reverb.conf << SUPEOF
[program:reverb]
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

supervisorctl reread
supervisorctl update
supervisorctl start all 2>/dev/null || true

# ---- Nginx ----
if [ "$OCTANE" = "y" ]; then
    LOCATION_BLOCK="try_files \$uri \$uri/ @octane;"
    OCTANE_LOCATION='
    location @octane {
        proxy_http_version 1.1;
        proxy_set_header Host $http_host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_pass http://127.0.0.1:8000;
    }'
else
    LOCATION_BLOCK="try_files \$uri \$uri/ /index.php?\$query_string;"
    OCTANE_LOCATION=""
fi

if [ "$REVERB" = "y" ]; then
    REVERB_LOCATION="
    location /app {
        proxy_http_version 1.1;
        proxy_set_header Host \$http_host;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection Upgrade;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_pass http://127.0.0.1:${REVERB_PORT};
    }"
else
    REVERB_LOCATION=""
fi

write_nginx_ssl() {
cat > /etc/nginx/sites-available/laravel << NGXEOF
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
    ${REVERB_LOCATION}
    location / { ${LOCATION_BLOCK} }
    location = /favicon.ico { access_log off; log_not_found off; }
    location = /robots.txt  { access_log off; log_not_found off; }
    ${OCTANE_LOCATION}
}
NGXEOF
}

write_nginx_http() {
cat > /etc/nginx/sites-available/laravel << NGXEOF
server {
    listen 80;
    server_name ${DOMAIN} www.${DOMAIN};
    root ${APP_DIR}/public;
    index index.php;
    charset utf-8;
    add_header X-Frame-Options SAMEORIGIN;
    add_header X-Content-Type-Options nosniff;
    ${REVERB_LOCATION}
    location / { ${LOCATION_BLOCK} }
    location = /favicon.ico { access_log off; log_not_found off; }
    location = /robots.txt  { access_log off; log_not_found off; }
    location ~ \.php$ {
        fastcgi_pass unix:/var/run/php/php${PHP_VER}-fpm.sock;
        fastcgi_param SCRIPT_FILENAME \$realpath_root\$fastcgi_script_name;
        include fastcgi_params;
    }
    ${OCTANE_LOCATION}
}
NGXEOF
}

rm -f /etc/nginx/sites-enabled/default
ln -sf /etc/nginx/sites-available/laravel /etc/nginx/sites-enabled/laravel

if [ "$SSL_MODE" = "cloudflare" ]; then
    if [ -f "$SSL_CERT" ] && [ -f "$SSL_KEY" ]; then
        write_nginx_ssl
        nginx -t && systemctl reload nginx
    else
        write_nginx_http
        nginx -t && systemctl reload nginx
        echo ""
        echo "  *** Running HTTP temporarily — SSL certs not found ***"
    fi
elif [ "$SSL_MODE" = "letsencrypt" ]; then
    write_nginx_http
    nginx -t && systemctl reload nginx
    apt install -y certbot python3-certbot-nginx
    certbot --nginx -d $DOMAIN -d www.$DOMAIN --non-interactive --agree-tos -m admin@$DOMAIN
    systemctl reload nginx
else
    write_nginx_http
    nginx -t && systemctl reload nginx
fi

# ---- Cache ----
php artisan config:cache
php artisan route:cache
php artisan view:cache

# ---- Firewall ----
ufw allow OpenSSH
ufw allow 'Nginx Full'
ufw --force enable

# ---- Done ----
echo ""
echo "=============================================="
echo "  DONE!"
echo "=============================================="
echo "  Domain  : https://$DOMAIN"
echo "  DB Name : $DB_NAME"
echo "  DB User : $DB_USER"
echo "  DB Pass : $DB_PASS   <-- SAVE THIS!"
echo ""
echo "  supervisorctl status"
echo "  supervisorctl restart octane"
echo "  supervisorctl restart horizon"
echo "  tail -f ${APP_DIR}/storage/logs/octane.log"
echo "=============================================="
if [ "$SSL_MODE" = "cloudflare" ] && [ ! -f "$SSL_CERT" ]; then
echo ""
echo "  CLOUDFLARE SSL NEXT STEPS:"
echo "  1. nano $SSL_CERT   (paste certificate)"
echo "  2. nano $SSL_KEY    (paste private key)"
echo "  3. Run: nginx -t && systemctl reload nginx"
echo "  4. Set Cloudflare SSL mode to Full (Strict)"
echo "=============================================="
fi