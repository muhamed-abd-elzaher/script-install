#!/bin/bash
################################################################################
# Script for installing Odoo 19 on RHEL 10 (Red Hat Enterprise Linux 10)
# Adapted from Yenthe Van Ginneken's InstallScript (Ubuntu version)
#-------------------------------------------------------------------------------
# This script will install Odoo on your RHEL 10 server. It can install multiple
# Odoo instances in one server because of the different xmlrpc_ports.
#-------------------------------------------------------------------------------
# Usage:
#   sudo nano odoo19_install_rhel10.sh
#   sudo chmod +x odoo19_install_rhel10.sh
#   sudo ./odoo19_install_rhel10.sh
################################################################################

#==================================================
# CONFIGURABLE PARAMETERS
#==================================================

OE_USER="odoo"
OE_HOME="/$OE_USER"
OE_HOME_EXT="/$OE_USER/${OE_USER}-server"

# Set to True to install wkhtmltopdf, False if already installed
INSTALL_WKHTMLTOPDF="True"

# Default Odoo port (use with -c /etc/odoo-server.conf)
OE_PORT="8069"

# Odoo version to install
OE_VERSION="19.0"

# Set to True to install Odoo Enterprise edition
# You MUST have access to https://github.com/odoo/enterprise (Odoo Partner)
IS_ENTERPRISE="False"

# PostgreSQL configuration
# Set to "local" to install PostgreSQL 17 server locally
# Set to "remote" to only install client libs (PostgreSQL is on another machine)
POSTGRESQL_MODE="remote"

# Remote PostgreSQL settings (only used when POSTGRESQL_MODE="remote")
DB_HOST="localhost"
DB_PORT="5432"
DB_USER="odoo"
DB_PASSWORD="False"

# Set to True to install Nginx as reverse proxy
INSTALL_NGINX="True"

# Superadmin (master) password
OE_SUPERADMIN="admin"

# Set to True to auto-generate a random password
GENERATE_RANDOM_PASSWORD="True"

OE_CONFIG="${OE_USER}-server"

# Website name for Nginx (set your domain, e.g. odoo.example.com)
WEBSITE_NAME="_"

# Longpolling / websocket port (used when workers > 0)
LONGPOLLING_PORT="8072"

# Workers configuration
# Set to 0 to auto-calculate based on CPU cores: (CPU * 2) + 1
# Set to a specific number to override
WORKERS=0

# Memory limits per worker (in bytes)
LIMIT_MEMORY_HARD=2684354560
LIMIT_MEMORY_SOFT=2147483648

# Max cron threads
MAX_CRON_THREADS=2

# SSL Configuration
ENABLE_SSL="True"
ADMIN_EMAIL="odoo@example.com"

#==================================================
# HELPER FUNCTIONS
#==================================================

# pip install with --break-system-packages if supported (PEP 668 on RHEL 10 / Python 3.12)
pip_install() {
  if pip3 help install 2>/dev/null | grep -q -- '--break-system-packages'; then
    sudo -H pip3 install --break-system-packages "$@"
  else
    sudo -H pip3 install "$@"
  fi
}

# dnf wrapper: use --nogpgcheck to work around stale/mismatched GPG keys on RHEL 10
dnf_install() {
  sudo dnf install -y --nogpgcheck "$@"
}

# Detect architecture
detect_arch() {
  local arch_raw
  arch_raw="$(uname -m)"
  case "$arch_raw" in
    x86_64)    ARCH="x86_64";;
    aarch64)   ARCH="aarch64";;
    *)         ARCH="$arch_raw";;
  esac

  # Get RHEL version info
  if [ -f /etc/redhat-release ]; then
    RHEL_VERSION=$(rpm -E %{rhel} 2>/dev/null || echo "10")
  else
    RHEL_VERSION="10"
  fi
}

detect_arch

# Auto-calculate workers if set to 0
if [ "$WORKERS" -eq 0 ]; then
    CPU_COUNT=$(nproc --all 2>/dev/null || echo 2)
    WORKERS=$(( CPU_COUNT * 2 + 1 ))
    echo "Auto-detected $CPU_COUNT CPU cores, setting workers to $WORKERS"
fi

echo "============================================================"
echo " Odoo 19 Installation Script for RHEL 10"
echo " Architecture: ${ARCH}"
echo " RHEL Version: ${RHEL_VERSION}"
echo " PostgreSQL:   ${POSTGRESQL_MODE}"
echo " Workers:      ${WORKERS}"
echo "============================================================"

#--------------------------------------------------
# Fix GPG Keys (RHEL 10 may have outdated/missing signing keys)
#--------------------------------------------------
echo -e "\n---- Updating RPM GPG keys ----"
sudo rpm --import /etc/pki/rpm-gpg/RPM-GPG-KEY-redhat-release 2>/dev/null || true
sudo rpm --import https://www.redhat.com/security/data/fd431d51.txt 2>/dev/null || true
sudo rpm --import https://www.redhat.com/security/team/key/ 2>/dev/null || true

# If GPG keys are still failing, allow update to proceed
# by refreshing the subscription and cleaning metadata
sudo subscription-manager refresh 2>/dev/null || true
sudo dnf clean all

#--------------------------------------------------
# Update Server
#--------------------------------------------------
echo -e "\n---- Update Server ----"
sudo dnf update -y --nogpgcheck
dnf_install dnf-utils

#--------------------------------------------------
# Install EPEL Repository (needed for some dependencies)
#--------------------------------------------------
echo -e "\n---- Install EPEL Repository ----"
dnf_install \
  https://dl.fedoraproject.org/pub/epel/epel-release-latest-${RHEL_VERSION}.noarch.rpm \
  2>/dev/null || dnf_install epel-release 2>/dev/null || true

# Enable CodeReady Builder / CRB equivalent (needed for some -devel packages)
sudo dnf config-manager --set-enabled crb 2>/dev/null || \
sudo dnf config-manager --set-enabled codeready-builder-for-rhel-${RHEL_VERSION}-${ARCH}-rpms 2>/dev/null || \
sudo subscription-manager repos --enable codeready-builder-for-rhel-${RHEL_VERSION}-${ARCH}-rpms 2>/dev/null || true

#--------------------------------------------------
# Install PostgreSQL
#--------------------------------------------------
echo -e "\n---- Install PostgreSQL (mode: ${POSTGRESQL_MODE}) ----"

# Install PGDG repository (needed for both modes)
dnf_install \
  https://download.postgresql.org/pub/repos/yum/reporpms/EL-${RHEL_VERSION}-${ARCH}/pgdg-redhat-repo-latest.noarch.rpm \
  2>/dev/null || true

# Import PGDG GPG key
sudo rpm --import https://download.postgresql.org/pub/repos/yum/keys/PGDG-RPM-GPG-KEY-RHEL 2>/dev/null || true

# Disable built-in PostgreSQL module to avoid conflicts
sudo dnf -qy module disable postgresql 2>/dev/null || true
sudo dnf clean all

if [ "$POSTGRESQL_MODE" = "local" ]; then
    echo -e "\n---- Installing PostgreSQL 17 Server locally ----"
    dnf_install postgresql17 postgresql17-server postgresql17-contrib postgresql17-devel

    # Initialize the database cluster
    sudo /usr/pgsql-17/bin/postgresql-17-setup initdb

    # Start and enable PostgreSQL
    sudo systemctl start postgresql-17
    sudo systemctl enable postgresql-17

    if [ "$IS_ENTERPRISE" = "True" ]; then
        # pgvector is needed for Enterprise AI features
        echo -e "\n---- Installing pgvector for Enterprise AI features ----"
        dnf_install pgvector_17 2>/dev/null || true

        # Wait for PostgreSQL to be ready
        until sudo -u postgres pg_isready >/dev/null 2>&1; do sleep 1; done

        # Create vector extension
        sudo -u postgres psql -v ON_ERROR_STOP=1 -d template1 <<'SQL'
CREATE EXTENSION IF NOT EXISTS vector;
SQL
    fi

    echo -e "\n---- Creating the ODOO PostgreSQL User ----"
    sudo su - postgres -c "createuser -s $OE_USER" 2>/dev/null || true

else
    echo -e "\n---- Installing PostgreSQL 17 client libs only (remote DB) ----"
    dnf_install postgresql17-libs postgresql17-devel postgresql17
fi

# Add psql/pg_config to PATH for this session and future logins
echo 'export PATH=/usr/pgsql-17/bin:$PATH' | sudo tee /etc/profile.d/postgresql17.sh
export PATH=/usr/pgsql-17/bin:$PATH

# Create symlinks so pg_config is always findable (even inside sudo)
sudo ln -sf /usr/pgsql-17/bin/pg_config /usr/bin/pg_config
sudo ln -sf /usr/pgsql-17/bin/psql /usr/bin/psql

#--------------------------------------------------
# Install System Dependencies
#--------------------------------------------------
echo -e "\n---- Installing Python 3 + pip3 ----"
dnf_install python3 python3-pip python3-devel python3-setuptools python3-wheel

echo -e "\n---- Installing system dependencies ----"
dnf_install \
    git \
    gcc \
    gcc-c++ \
    make \
    wget \
    curl \
    bzip2-devel \
    freetype-devel \
    lcms2-devel \
    libjpeg-turbo-devel \
    libpng-devel \
    libtiff-devel \
    libwebp-devel \
    libxml2-devel \
    libxslt-devel \
    libzip-devel \
    openldap-devel \
    cyrus-sasl-devel \
    openssl-devel \
    libffi-devel \
    zlib-devel \
    redhat-rpm-config \
    xorg-x11-fonts-Type1 \
    xorg-x11-fonts-75dpi

echo -e "\n---- Install Python packages / Odoo 19 requirements ----"
pip_install -r "https://github.com/odoo/odoo/raw/${OE_VERSION}/requirements.txt"

# Ensure phonenumbers is installed
pip_install phonenumbers

echo -e "\n---- Installing Node.js, npm and rtlcss for LTR support ----"
# Install Node.js from RHEL AppStream (or NodeSource if needed)
dnf_install nodejs npm 2>/dev/null

# If nodejs version is too old or not available, install from NodeSource
if ! command -v node >/dev/null 2>&1; then
    echo -e "\n---- Node.js not found in AppStream, installing from NodeSource ----"
    curl -fsSL https://rpm.nodesource.com/setup_20.x | sudo bash -
    dnf_install nodejs
fi

echo -e "---- Node.js version: $(node --version 2>/dev/null || echo 'not found') ----"
echo -e "---- npm version: $(npm --version 2>/dev/null || echo 'not found') ----"

sudo npm install -g rtlcss

#--------------------------------------------------
# Install Wkhtmltopdf
#--------------------------------------------------
if [ "$INSTALL_WKHTMLTOPDF" = "True" ]; then
    echo -e "\n---- Installing wkhtmltopdf (architecture: $ARCH) ----"

    # Install wkhtmltopdf dependencies
    dnf_install \
        libXrender \
        libXext \
        fontconfig \
        freetype \
        libpng \
        libjpeg-turbo \
        xorg-x11-fonts-Type1 \
        xorg-x11-fonts-75dpi

    # Try to install wkhtmltopdf from available sources
    # First try the AlmaLinux 9 / RHEL 9 compatible RPM (works on RHEL 10)
    WKHTML_RPM=""
    if [ "$ARCH" = "x86_64" ]; then
        WKHTML_RPM="https://github.com/wkhtmltopdf/packaging/releases/download/0.12.6.1-3/wkhtmltox-0.12.6.1-3.almalinux9.x86_64.rpm"
    elif [ "$ARCH" = "aarch64" ]; then
        WKHTML_RPM="https://github.com/wkhtmltopdf/packaging/releases/download/0.12.6.1-3/wkhtmltox-0.12.6.1-3.almalinux9.aarch64.rpm"
    fi

    if [ -n "$WKHTML_RPM" ]; then
        echo -e "---- Downloading wkhtmltopdf RPM ----"
        wget -q "$WKHTML_RPM" -O /tmp/wkhtmltox.rpm 2>/dev/null

        if [ -f /tmp/wkhtmltox.rpm ] && [ -s /tmp/wkhtmltox.rpm ]; then
            echo -e "---- Installing wkhtmltopdf RPM ----"
            sudo dnf localinstall -y --nogpgcheck /tmp/wkhtmltox.rpm 2>/dev/null || \
            sudo rpm -Uvh --nodeps /tmp/wkhtmltox.rpm 2>/dev/null || true
            rm -f /tmp/wkhtmltox.rpm
        else
            echo -e "---- Download failed. Trying dnf install... ----"
            dnf_install wkhtmltopdf 2>/dev/null || true
        fi
    else
        echo -e "---- Unsupported architecture for wkhtmltopdf: $ARCH ----"
        dnf_install wkhtmltopdf 2>/dev/null || true
    fi

    # Create symlinks if needed
    if [ -x /usr/local/bin/wkhtmltopdf ] && ! command -v wkhtmltopdf >/dev/null 2>&1; then
        sudo ln -sf /usr/local/bin/wkhtmltopdf /usr/bin/wkhtmltopdf
    fi
    if [ -x /usr/local/bin/wkhtmltoimage ] && ! command -v wkhtmltoimage >/dev/null 2>&1; then
        sudo ln -sf /usr/local/bin/wkhtmltoimage /usr/bin/wkhtmltoimage
    fi

    if command -v wkhtmltopdf >/dev/null 2>&1; then
        echo -e "\n---- wkhtmltopdf installed: $(wkhtmltopdf --version 2>/dev/null) ----"
    else
        echo -e "\n---- WARNING: wkhtmltopdf not installed. Install manually later. ----"
    fi
else
    echo "Wkhtmltopdf will not be installed (user choice)."
fi

#--------------------------------------------------
# Create ODOO system user
#--------------------------------------------------
echo -e "\n---- Create ODOO system user ----"
sudo adduser --system --shell=/bin/bash --home-dir=$OE_HOME --user-group $OE_USER 2>/dev/null || \
sudo useradd --system --shell /bin/bash --home-dir $OE_HOME --create-home --user-group $OE_USER 2>/dev/null || true

echo -e "\n---- Create Log directory ----"
sudo mkdir -p /var/log/$OE_USER
sudo chown $OE_USER:$OE_USER /var/log/$OE_USER

#--------------------------------------------------
# Install ODOO 19
#--------------------------------------------------
echo -e "\n==== Installing ODOO 19 Server ===="
# Mark directories as safe for git (needed when re-running script with different user)
sudo git config --global --add safe.directory $OE_HOME_EXT
sudo git config --global --add safe.directory "$OE_HOME/enterprise/addons"

if [ -d "$OE_HOME_EXT/.git" ]; then
    echo "---- Odoo source already exists, pulling latest changes ----"
    sudo git -C $OE_HOME_EXT pull
else
    sudo git clone --depth 1 --branch $OE_VERSION https://www.github.com/odoo/odoo $OE_HOME_EXT/
fi

if [ "$IS_ENTERPRISE" = "True" ]; then
    # Odoo Enterprise install!
    pip_install psycopg2-binary pdfminer.six
    sudo su $OE_USER -c "mkdir -p $OE_HOME/enterprise"
    sudo su $OE_USER -c "mkdir -p $OE_HOME/enterprise/addons"

    if [ -d "$OE_HOME/enterprise/addons/.git" ]; then
        echo "---- Enterprise source already exists, pulling latest changes ----"
        sudo git -C "$OE_HOME/enterprise/addons" pull
    else
        GITHUB_RESPONSE=$(sudo git clone --depth 1 --branch $OE_VERSION https://www.github.com/odoo/enterprise "$OE_HOME/enterprise/addons" 2>&1)
        while [[ $GITHUB_RESPONSE == *"Authentication"* ]]; do
            echo "-----------------------------------------------------------"
            echo "WARNING: GitHub authentication failed! Please try again."
            echo ""
            echo "To clone Odoo Enterprise you need to be an official Odoo"
            echo "partner with access to: https://github.com/odoo/enterprise"
            echo ""
            echo "TIP: Press Ctrl+C to stop this script."
            echo "-----------------------------------------------------------"
            GITHUB_RESPONSE=$(sudo git clone --depth 1 --branch $OE_VERSION https://www.github.com/odoo/enterprise "$OE_HOME/enterprise/addons" 2>&1)
        done
    fi

    echo -e "\n---- Enterprise code installed under $OE_HOME/enterprise/addons ----"
    echo -e "\n---- Installing Enterprise-specific libraries ----"
    pip_install num2words ofxparse dbfread ebaysdk firebase_admin pyOpenSSL
    sudo npm install -g less
    sudo npm install -g less-plugin-clean-css
fi

echo -e "\n---- Setting permissions on home folder ----"
sudo chown -R $OE_USER:$OE_USER $OE_HOME/

echo -e "\n---- Fix SELinux context for Odoo binary ----"
sudo restorecon -R $OE_HOME/ 2>/dev/null || true
sudo chcon -t bin_t $OE_HOME_EXT/odoo-bin 2>/dev/null || true

echo -e "\n---- Create custom module directory ----"
sudo su $OE_USER -c "mkdir -p $OE_HOME/custom"
sudo su $OE_USER -c "mkdir -p $OE_HOME/custom/addons"

#--------------------------------------------------
# Create server config file
#--------------------------------------------------
echo -e "\n---- Creating server config file ----"

if [ "$GENERATE_RANDOM_PASSWORD" = "True" ]; then
    echo -e "* Generating random admin password"
    OE_SUPERADMIN=$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 16 | head -n 1)
fi

# Build addons_path
if [ "$IS_ENTERPRISE" = "True" ]; then
    ADDONS_PATH="${OE_HOME}/enterprise/addons,${OE_HOME_EXT}/addons,${OE_HOME}/custom/addons"
else
    ADDONS_PATH="${OE_HOME_EXT}/addons,${OE_HOME}/custom/addons"
fi

# Build database config
if [ "$POSTGRESQL_MODE" = "remote" ]; then
    DB_CONFIG="db_host = ${DB_HOST}
db_port = ${DB_PORT}
db_user = ${DB_USER}
db_password = ${DB_PASSWORD}"
else
    DB_CONFIG="db_host = False
db_port = False
db_user = ${OE_USER}
db_password = False"
fi

sudo bash -c "cat > /etc/${OE_CONFIG}.conf" <<EOF
[options]
; This is the password that allows database operations:
admin_passwd = ${OE_SUPERADMIN}
http_port = ${OE_PORT}
logfile = /var/log/${OE_USER}/${OE_CONFIG}.log
addons_path = ${ADDONS_PATH}

; Database
${DB_CONFIG}

; Workers and performance
workers = ${WORKERS}
max_cron_threads = ${MAX_CRON_THREADS}
limit_memory_hard = ${LIMIT_MEMORY_HARD}
limit_memory_soft = ${LIMIT_MEMORY_SOFT}
limit_time_cpu = 600
limit_time_real = 1200
limit_time_real_cron = -1
limit_request = 65536

; Proxy mode (must be True when behind Nginx)
proxy_mode = True

; Gevent port for websocket (used when workers > 0)
gevent_port = ${LONGPOLLING_PORT}
EOF

sudo chown $OE_USER:$OE_USER /etc/${OE_CONFIG}.conf
sudo chmod 640 /etc/${OE_CONFIG}.conf

#--------------------------------------------------
# Create startup script
#--------------------------------------------------
echo -e "\n---- Creating startup script ----"
sudo bash -c "cat > $OE_HOME_EXT/start.sh" <<EOF
#!/bin/sh
sudo -u $OE_USER $OE_HOME_EXT/odoo-bin --config=/etc/${OE_CONFIG}.conf
EOF
sudo chmod 755 $OE_HOME_EXT/start.sh

#--------------------------------------------------
# Create systemd service file
#--------------------------------------------------
echo -e "\n---- Creating systemd service file ----"

# Determine service dependencies based on PostgreSQL mode
if [ "$POSTGRESQL_MODE" = "local" ]; then
    PG_UNIT_AFTER="After=network.target postgresql-17.service"
    PG_UNIT_REQUIRES="Requires=postgresql-17.service"
else
    PG_UNIT_AFTER="After=network.target"
    PG_UNIT_REQUIRES=""
fi

sudo bash -c "cat > /etc/systemd/system/${OE_CONFIG}.service" <<EOF
[Unit]
Description=Odoo 19
Documentation=https://www.odoo.com
${PG_UNIT_AFTER}
${PG_UNIT_REQUIRES}

[Service]
Type=simple
SyslogIdentifier=${OE_CONFIG}
PermissionsStartOnly=true
User=${OE_USER}
Group=${OE_USER}
ExecStart=${OE_HOME_EXT}/odoo-bin -c /etc/${OE_CONFIG}.conf
StandardOutput=journal+console
Restart=on-failure
RestartSec=5
KillMode=mixed

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable ${OE_CONFIG}.service

#--------------------------------------------------
# Configure SELinux (allow Odoo to bind to its port)
#--------------------------------------------------
echo -e "\n---- Configuring SELinux for Odoo ----"

# Install SELinux policy tools if not present
dnf_install policycoreutils-python-utils 2>/dev/null || true

if command -v getenforce >/dev/null 2>&1; then
    SELINUX_STATUS=$(getenforce)
    echo -e "---- SELinux is: $SELINUX_STATUS ----"

    if [ "$SELINUX_STATUS" != "Disabled" ]; then
        # Allow Odoo to bind to its port
        sudo semanage port -a -t http_port_t -p tcp ${OE_PORT} 2>/dev/null || \
        sudo semanage port -m -t http_port_t -p tcp ${OE_PORT} 2>/dev/null || true

        sudo semanage port -a -t http_port_t -p tcp ${LONGPOLLING_PORT} 2>/dev/null || \
        sudo semanage port -m -t http_port_t -p tcp ${LONGPOLLING_PORT} 2>/dev/null || true

        # Allow httpd (Nginx) to connect to Odoo backend
        sudo setsebool -P httpd_can_network_connect 1 2>/dev/null || true

        # Restore SELinux context on Odoo directories
        sudo restorecon -R $OE_HOME 2>/dev/null || true
        sudo restorecon -R /var/log/$OE_USER 2>/dev/null || true

        echo -e "---- SELinux configured for Odoo ----"
    fi
else
    echo -e "---- SELinux tools not found, skipping ----"
fi

#--------------------------------------------------
# Configure firewalld
#--------------------------------------------------
echo -e "\n---- Configuring firewall ----"
if systemctl is-active --quiet firewalld; then
    echo -e "---- Opening port $OE_PORT in firewalld ----"
    sudo firewall-cmd --permanent --add-port=${OE_PORT}/tcp
    sudo firewall-cmd --permanent --add-port=${LONGPOLLING_PORT}/tcp

    if [ "$INSTALL_NGINX" = "True" ]; then
        sudo firewall-cmd --permanent --add-service=http
        sudo firewall-cmd --permanent --add-service=https
    fi

    sudo firewall-cmd --reload
    echo -e "---- Firewall configured ----"
else
    echo -e "---- firewalld is not running, skipping ----"
fi

#--------------------------------------------------
# Install Nginx if needed
#--------------------------------------------------
if [ "$INSTALL_NGINX" = "True" ]; then
    echo -e "\n---- Installing and configuring Nginx ----"
    dnf_install nginx

    # Determine if we should configure SSL
    CONFIGURE_SSL="False"
    if [ "$ENABLE_SSL" = "True" ] && [ "$ADMIN_EMAIL" != "odoo@example.com" ] && [ "$WEBSITE_NAME" != "_" ]; then
        CONFIGURE_SSL="True"
    fi

    if [ "$CONFIGURE_SSL" = "True" ]; then
        #----------------------------------------------
        # Step 1: Write temporary HTTP-only config for Certbot challenge
        #----------------------------------------------
        echo -e "\n---- Writing temporary HTTP config for Certbot ----"
        sudo bash -c "cat > /etc/nginx/conf.d/${OE_CONFIG}.conf" <<'NGINXEOF'
server {
    listen 80;
    server_name WEBSITE_NAME_PLACEHOLDER;

    location / {
        proxy_pass http://127.0.0.1:OE_PORT_PLACEHOLDER;
    }
}
NGINXEOF

        sudo sed -i "s/OE_PORT_PLACEHOLDER/$OE_PORT/g" /etc/nginx/conf.d/${OE_CONFIG}.conf
        sudo sed -i "s/WEBSITE_NAME_PLACEHOLDER/$WEBSITE_NAME/g" /etc/nginx/conf.d/${OE_CONFIG}.conf

        sudo systemctl enable nginx
        sudo systemctl start nginx
        sudo systemctl reload nginx

        #----------------------------------------------
        # Step 2: Obtain SSL certificate with Certbot
        #----------------------------------------------
        echo -e "\n---- Installing Certbot and obtaining SSL certificate ----"
        dnf_install certbot python3-certbot-nginx
        sudo certbot certonly --nginx -d $WEBSITE_NAME --noninteractive --agree-tos --email $ADMIN_EMAIL

        if [ ! -f /etc/letsencrypt/live/$WEBSITE_NAME/fullchain.pem ]; then
            echo "WARNING: Certbot failed to obtain certificate."
            echo "  -> Make sure DNS for $WEBSITE_NAME points to this server."
            echo "  -> Falling back to HTTP-only config."
            CONFIGURE_SSL="False"
        fi
    fi

    if [ "$CONFIGURE_SSL" = "True" ]; then
        #----------------------------------------------
        # Step 3: Write final HTTPS Nginx config
        #----------------------------------------------
        echo -e "\n---- Writing HTTPS Nginx config ----"
        sudo bash -c "cat > /etc/nginx/conf.d/${OE_CONFIG}.conf" <<'NGINXEOF'
# Odoo backend upstream
upstream odoo {
    server 127.0.0.1:OE_PORT_PLACEHOLDER;
}

# Odoo gevent upstream (websocket)
upstream odoochat {
    server 127.0.0.1:LONGPOLLING_PORT_PLACEHOLDER;
}

# Required for websocket upgrade (must be at http context level)
map $http_upgrade $connection_upgrade {
    default upgrade;
    ''      close;
}

# HTTP -> HTTPS redirect
server {
    listen 80;
    server_name WEBSITE_NAME_PLACEHOLDER;
    return 301 https://$host$request_uri;
}

# HTTPS server
server {
    listen 443 ssl http2;
    server_name WEBSITE_NAME_PLACEHOLDER;

    # SSL certificates (Let's Encrypt)
    ssl_certificate /etc/letsencrypt/live/WEBSITE_NAME_PLACEHOLDER/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/WEBSITE_NAME_PLACEHOLDER/privkey.pem;
    ssl_session_timeout 30m;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384;
    ssl_prefer_server_ciphers off;

    # Timeouts
    proxy_read_timeout 720s;
    proxy_connect_timeout 720s;
    proxy_send_timeout 720s;

    # Log files
    access_log /var/log/nginx/OE_USER_PLACEHOLDER-access.log;
    error_log  /var/log/nginx/OE_USER_PLACEHOLDER-error.log;

    # Request limits
    client_max_body_size 0;

    # Redirect websocket requests to odoo gevent port
    location /websocket {
        proxy_pass http://odoochat;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection $connection_upgrade;
        proxy_set_header X-Forwarded-Host $http_host;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header X-Real-IP $remote_addr;

        add_header Strict-Transport-Security "max-age=31536000; includeSubDomains";
        proxy_cookie_flags session_id samesite=lax secure;
    }

    # Redirect requests to odoo backend server
    location / {
        proxy_pass http://odoo;
        proxy_redirect off;
        proxy_set_header X-Forwarded-Host $http_host;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header X-Real-IP $remote_addr;

        add_header Strict-Transport-Security "max-age=31536000; includeSubDomains";
        proxy_cookie_flags session_id samesite=lax secure;
    }

    # Common gzip
    gzip_types text/css text/scss text/plain text/xml application/xml application/json application/javascript;
    gzip on;
}
NGINXEOF

        # Set up auto-renewal cron for Let's Encrypt
        echo -e "\n---- Setting up Certbot auto-renewal ----"
        (sudo crontab -l 2>/dev/null; echo "0 0,12 * * * certbot renew --quiet --post-hook 'systemctl reload nginx'") | sudo crontab - 2>/dev/null || true

        echo "SSL/HTTPS is enabled with Let's Encrypt!"

    else
        #----------------------------------------------
        # HTTP-only Nginx config (no SSL)
        #----------------------------------------------
        echo -e "\n---- Writing HTTP-only Nginx config ----"
        sudo bash -c "cat > /etc/nginx/conf.d/${OE_CONFIG}.conf" <<'NGINXEOF'
# Odoo backend upstream
upstream odoo {
    server 127.0.0.1:OE_PORT_PLACEHOLDER;
}

# Odoo gevent upstream (websocket)
upstream odoochat {
    server 127.0.0.1:LONGPOLLING_PORT_PLACEHOLDER;
}

# Required for websocket upgrade (must be at http context level)
map $http_upgrade $connection_upgrade {
    default upgrade;
    ''      close;
}

server {
    listen 80;
    server_name WEBSITE_NAME_PLACEHOLDER;

    # Timeouts
    proxy_read_timeout 720s;
    proxy_connect_timeout 720s;
    proxy_send_timeout 720s;

    # Log files
    access_log /var/log/nginx/OE_USER_PLACEHOLDER-access.log;
    error_log  /var/log/nginx/OE_USER_PLACEHOLDER-error.log;

    # Request limits
    client_max_body_size 0;

    # Redirect websocket requests to odoo gevent port
    location /websocket {
        proxy_pass http://odoochat;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection $connection_upgrade;
        proxy_set_header X-Forwarded-Host $http_host;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header X-Real-IP $remote_addr;
    }

    # Redirect requests to odoo backend server
    location / {
        proxy_pass http://odoo;
        proxy_redirect off;
        proxy_set_header X-Forwarded-Host $http_host;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header X-Real-IP $remote_addr;
    }

    # Common gzip
    gzip_types text/css text/scss text/plain text/xml application/xml application/json application/javascript;
    gzip on;
}
NGINXEOF

        if [ "$ENABLE_SSL" = "True" ]; then
            echo "SSL/HTTPS not enabled."
            if [ "$ADMIN_EMAIL" = "odoo@example.com" ]; then
                echo "  -> Set ADMIN_EMAIL to a real email address."
            fi
            if [ "$WEBSITE_NAME" = "_" ]; then
                echo "  -> Set WEBSITE_NAME to your domain (e.g. odoo.example.com)."
            fi
        fi
    fi

    # Replace placeholders with actual values
    sudo sed -i "s/OE_PORT_PLACEHOLDER/$OE_PORT/g" /etc/nginx/conf.d/${OE_CONFIG}.conf
    sudo sed -i "s/LONGPOLLING_PORT_PLACEHOLDER/$LONGPOLLING_PORT/g" /etc/nginx/conf.d/${OE_CONFIG}.conf
    sudo sed -i "s/WEBSITE_NAME_PLACEHOLDER/$WEBSITE_NAME/g" /etc/nginx/conf.d/${OE_CONFIG}.conf
    sudo sed -i "s/OE_USER_PLACEHOLDER/$OE_USER/g" /etc/nginx/conf.d/${OE_CONFIG}.conf

    # Start / reload Nginx
    sudo systemctl enable nginx
    sudo systemctl start nginx
    sudo nginx -t && sudo systemctl reload nginx

    echo "Nginx configured. File: /etc/nginx/conf.d/${OE_CONFIG}.conf"
else
    echo "Nginx not installed (user choice)."
fi

#--------------------------------------------------
# Start Odoo
#--------------------------------------------------
echo -e "\n---- Starting Odoo 19 Service ----"
sudo systemctl start ${OE_CONFIG}.service

echo "============================================================"
echo " Odoo 19 Installation Complete on RHEL 10!"
echo "============================================================"
echo ""
echo " Port:                  $OE_PORT"
echo " Longpolling port:      $LONGPOLLING_PORT"
echo " Workers:               $WORKERS"
echo " Service user:          $OE_USER"
echo " Config file:           /etc/${OE_CONFIG}.conf"
echo " Log file:              /var/log/$OE_USER/${OE_CONFIG}.log"
echo ""
if [ "$POSTGRESQL_MODE" = "local" ]; then
echo " PostgreSQL:            local (postgresql-17)"
echo " PostgreSQL user:       $OE_USER"
else
echo " PostgreSQL:            remote (${DB_HOST}:${DB_PORT})"
echo " DB user:               $DB_USER"
fi
echo ""
echo " Code location:         $OE_HOME_EXT"
if [ "$IS_ENTERPRISE" = "True" ]; then
echo " Enterprise addons:     $OE_HOME/enterprise/addons"
fi
echo " Custom addons:         $OE_HOME/custom/addons"
echo " Superadmin password:   $OE_SUPERADMIN"
echo ""
echo " Service commands:"
echo "   sudo systemctl start ${OE_CONFIG}"
echo "   sudo systemctl stop ${OE_CONFIG}"
echo "   sudo systemctl restart ${OE_CONFIG}"
echo "   sudo systemctl status ${OE_CONFIG}"
echo "   sudo journalctl -u ${OE_CONFIG} -f    (live logs)"
echo ""
if [ "$INSTALL_NGINX" = "True" ]; then
    echo " Nginx config:          /etc/nginx/conf.d/${OE_CONFIG}.conf"
fi
echo ""
echo " SELinux: If you have issues, check:"
echo "   sudo audit2why -a"
echo "   sudo sealert -a /var/log/audit/audit.log"
echo ""
echo " Firewall: Ports $OE_PORT and $LONGPOLLING_PORT are open."
echo "============================================================"
