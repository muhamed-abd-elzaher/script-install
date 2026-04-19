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

OE_USER="odooapp"
OE_HOME="/opt/odoo"
OE_HOME_EXT="/opt/odoo/odoo-server"
# Path to manually uploaded Odoo source (used when GitHub is blocked).
# Can be a zip (/tmp/odoo-19.0.zip) or an already-extracted folder.
# Leave empty to attempt git clone from GitHub.
OE_LOCAL_SOURCE="/tmp/odoo-19.0.zip"
# Path to manually uploaded requirements.txt (used when GitHub is blocked).
OE_LOCAL_REQUIREMENTS="/tmp/requirements.txt"

# OFFLINE MODE: pre-downloaded packages for airgapped / proxy-blocked environments
# Leave empty to use online sources (PyPI, PGDG, npm).
# When set, these folders MUST contain the required files.
#
# Python wheels: create on another machine with
#   pip download -r requirements.txt -d /tmp/pip-packages/
#   tar czf pip-packages.tar.gz pip-packages/
# Then upload and extract to /tmp/pip-packages/
PIP_LOCAL_DIR="/tmp/pip-packages"

# PostgreSQL 17 RPMs: download all from
#   https://download.postgresql.org/pub/repos/yum/17/redhat/rhel-10-x86_64/
# (need at least postgresql17, postgresql17-libs, postgresql17-server,
#  postgresql17-contrib, postgresql17-devel and their deps)
PG17_LOCAL_DIR="/tmp/pg17-rpms"

# Set to True to install wkhtmltopdf.
# If github.com is blocked, upload the RPM manually to /tmp/wkhtmltox.rpm
# Download from: https://github.com/wkhtmltopdf/packaging/releases/download/0.12.6.1-3/wkhtmltox-0.12.6.1-3.almalinux9.x86_64.rpm
INSTALL_WKHTMLTOPDF="True"

# Default Odoo port (use with -c /etc/odoo-server.conf)
OE_PORT="8069"

# Odoo version to install
OE_VERSION="19.0"

# Set to True to install Odoo Enterprise edition
# You MUST have access to https://github.com/odoo/enterprise (Odoo Partner)
IS_ENTERPRISE="False"

# PostgreSQL configuration
# Set to "local" to install PostgreSQL server locally (uses PGDG 17 if reachable,
#   else RHEL AppStream PostgreSQL)
# Set to "remote" to only install client libs (PostgreSQL is on another machine)
POSTGRESQL_MODE="local"

# Remote PostgreSQL settings (only used when POSTGRESQL_MODE="remote")
# Ignored when POSTGRESQL_MODE="local"
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
# Set to 0 to auto-calculate based on CPU cores: (CPU * 2) + 1 (capped at MAX_WORKERS)
# Set to a specific number to override (recommended for large servers: 8-16)
WORKERS=8

# Memory limits per worker (in bytes)
LIMIT_MEMORY_HARD=2684354560
LIMIT_MEMORY_SOFT=2147483648

# Max cron threads
MAX_CRON_THREADS=2

# SSL Configuration
# HTTPS with self-signed certificate is always enabled by default.
# To use Let's Encrypt (free trusted cert), set ENABLE_SSL="True",
# WEBSITE_NAME to your domain, and ADMIN_EMAIL to your real email.
# If Let's Encrypt fails, it falls back to the self-signed cert.
ENABLE_SSL="True"
ADMIN_EMAIL="odoo@example.com"

#==================================================
# HELPER FUNCTIONS
#==================================================

# pip install:
# - If PIP_LOCAL_DIR exists and has wheels, use offline mode (no network)
# - Otherwise use PyPI (preserving proxy env vars)
# - --break-system-packages handles PEP 668 on RHEL 10 / Python 3.12
pip_install() {
  local BREAK_FLAG=""
  if pip3 help install 2>/dev/null | grep -q -- '--break-system-packages'; then
    BREAK_FLAG="--break-system-packages"
  fi

  # Offline mode: use local wheels
  if [ -n "$PIP_LOCAL_DIR" ] && [ -d "$PIP_LOCAL_DIR" ] && \
     [ "$(ls -A "$PIP_LOCAL_DIR" 2>/dev/null)" ]; then
    echo "pip_install: using offline wheels from $PIP_LOCAL_DIR"
    sudo -H pip3 install $BREAK_FLAG --no-index --find-links="$PIP_LOCAL_DIR" "$@"
    return $?
  fi

  # Online mode: preserve proxy env vars through sudo
  local PIP_ENV=""
  [ -n "$http_proxy" ]  && PIP_ENV="$PIP_ENV http_proxy=$http_proxy"
  [ -n "$https_proxy" ] && PIP_ENV="$PIP_ENV https_proxy=$https_proxy"
  [ -n "$no_proxy" ]    && PIP_ENV="$PIP_ENV no_proxy=$no_proxy"
  sudo -H env $PIP_ENV pip3 install $BREAK_FLAG "$@"
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
# Capped at MAX_WORKERS because each worker uses ~2GB RAM
MAX_WORKERS=32
if [ "$WORKERS" -eq 0 ]; then
    CPU_COUNT=$(nproc --all 2>/dev/null || echo 2)
    WORKERS=$(( CPU_COUNT * 2 + 1 ))
    if [ "$WORKERS" -gt "$MAX_WORKERS" ]; then
        echo "Auto-detected $CPU_COUNT CPU cores. Formula (CPU*2+1)=$WORKERS exceeds cap of $MAX_WORKERS."
        echo "Setting workers to $MAX_WORKERS (edit MAX_WORKERS to change)."
        WORKERS=$MAX_WORKERS
    else
        echo "Auto-detected $CPU_COUNT CPU cores, setting workers to $WORKERS"
    fi
fi

echo "============================================================"
echo " Odoo 19 Installation Script for RHEL 10"
echo " Architecture: ${ARCH}"
echo " RHEL Version: ${RHEL_VERSION}"
echo " PostgreSQL:   ${POSTGRESQL_MODE}"
echo " Workers:      ${WORKERS}"
echo "============================================================"

#--------------------------------------------------
# Preflight connectivity check
#--------------------------------------------------
echo -e "\n---- Preflight: checking connectivity to external sources ----"
check_url() {
    local name="$1"
    local url="$2"
    local critical="$3"
    if timeout 5 curl -fsSI "$url" >/dev/null 2>&1; then
        echo "  [OK]    $name"
        return 0
    else
        echo "  [FAIL]  $name ${critical:+(CRITICAL)} - $url"
        return 1
    fi
}

echo "Local uploaded files:"
for f in "$OE_LOCAL_SOURCE" "$OE_LOCAL_REQUIREMENTS" "/tmp/pgdg-redhat-repo-latest.noarch.rpm" "/tmp/wkhtmltox.rpm"; do
    if [ -f "$f" ]; then
        echo "  [OK]    $f ($(du -h "$f" | cut -f1))"
    else
        echo "  [MISS]  $f"
    fi
done

echo ""
echo "Offline package directories (optional, for airgapped installs):"
for d in "$PIP_LOCAL_DIR" "$PG17_LOCAL_DIR"; do
    if [ -n "$d" ] && [ -d "$d" ] && [ "$(ls -A "$d" 2>/dev/null)" ]; then
        count=$(ls -1 "$d" 2>/dev/null | wc -l)
        echo "  [OK]    $d ($count files)"
    else
        echo "  [MISS]  $d (will use online sources)"
    fi
done

echo ""
echo "External connectivity:"
check_url "PyPI (Python packages)"          "https://pypi.org/"
check_url "files.pythonhosted.org"          "https://files.pythonhosted.org/"
check_url "PostgreSQL yum"                  "https://download.postgresql.org/"
check_url "npm registry"                    "https://registry.npmjs.org/"
check_url "EPEL"                            "https://dl.fedoraproject.org/"
check_url "GitHub"                          "https://github.com/"

echo ""
echo "Press Ctrl+C within 5 seconds to abort if connectivity looks wrong..."
sleep 5

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
echo -e "\n---- Install EPEL Repository (optional, skipped behind proxy) ----"
# EPEL is external and may be blocked by corporate proxy. Try but don't fail.
timeout 15 sudo dnf install -y --nogpgcheck \
  https://dl.fedoraproject.org/pub/epel/epel-release-latest-${RHEL_VERSION}.noarch.rpm \
  2>/dev/null || timeout 15 sudo dnf install -y --nogpgcheck epel-release 2>/dev/null || \
  echo "INFO: EPEL repo not installed (external mirror not reachable). Continuing without EPEL."

# Enable CodeReady Builder / CRB equivalent (needed for some -devel packages)
sudo dnf config-manager --set-enabled crb 2>/dev/null || \
sudo dnf config-manager --set-enabled codeready-builder-for-rhel-${RHEL_VERSION}-${ARCH}-rpms 2>/dev/null || \
sudo subscription-manager repos --enable codeready-builder-for-rhel-${RHEL_VERSION}-${ARCH}-rpms 2>/dev/null || true

#--------------------------------------------------
# Install PostgreSQL 17
#--------------------------------------------------
echo -e "\n---- Install PostgreSQL 17 (mode: ${POSTGRESQL_MODE}) ----"

# Try to set up PGDG repo:
#   1. Check if a local RPM exists (for proxy-blocked environments)
#   2. Otherwise try to download from download.postgresql.org
PGDG_AVAILABLE="False"

# If offline PG17 RPMs are provided, skip PGDG repo setup entirely
if [ -n "$PG17_LOCAL_DIR" ] && [ -d "$PG17_LOCAL_DIR" ] && \
   [ "$(ls -A "$PG17_LOCAL_DIR" 2>/dev/null)" ]; then
    echo "Using offline PG17 RPMs from $PG17_LOCAL_DIR - skipping PGDG repo setup"
    sudo dnf -qy module disable postgresql 2>/dev/null || true
    PGDG_AVAILABLE="Offline"
elif [ -f /tmp/pgdg-redhat-repo-latest.noarch.rpm ]; then
    echo "Using locally provided PGDG RPM at /tmp/pgdg-redhat-repo-latest.noarch.rpm"
    sudo dnf install -y --nogpgcheck /tmp/pgdg-redhat-repo-latest.noarch.rpm 2>/dev/null \
        && PGDG_AVAILABLE="True"
else
    timeout 15 sudo dnf install -y --nogpgcheck \
      https://download.postgresql.org/pub/repos/yum/reporpms/EL-${RHEL_VERSION}-${ARCH}/pgdg-redhat-repo-latest.noarch.rpm \
      2>/dev/null && PGDG_AVAILABLE="True"
fi

if [ "$PGDG_AVAILABLE" = "True" ]; then
    sudo rpm --import https://download.postgresql.org/pub/repos/yum/keys/PGDG-RPM-GPG-KEY-RHEL 2>/dev/null || true
    sudo dnf -qy module disable postgresql 2>/dev/null || true
    sudo dnf clean all
elif [ "$PGDG_AVAILABLE" = "False" ]; then
    echo ""
    echo "======================================================"
    echo "ERROR: Cannot install PostgreSQL 17."
    echo "======================================================"
    echo ""
    echo "You need ONE of these:"
    echo ""
    echo " A) Working network access to download.postgresql.org"
    echo ""
    echo " B) /tmp/pgdg-redhat-repo-latest.noarch.rpm uploaded manually"
    echo "    (then still needs yum.postgresql.org access to download RPMs)"
    echo ""
    echo " C) Pre-downloaded PG17 RPMs in $PG17_LOCAL_DIR (full offline mode)"
    echo "    Download all RPMs from:"
    echo "    https://download.postgresql.org/pub/repos/yum/17/redhat/rhel-10-x86_64/"
    echo "    Needed: postgresql17, postgresql17-libs, postgresql17-server,"
    echo "            postgresql17-contrib, postgresql17-devel"
    echo ""
    exit 1
fi

# Helper: install PG17 packages from offline dir or PGDG online
install_pg17_packages() {
    local pkgs="$*"
    if [ -n "$PG17_LOCAL_DIR" ] && [ -d "$PG17_LOCAL_DIR" ] && \
       [ "$(ls -A "$PG17_LOCAL_DIR" 2>/dev/null)" ]; then
        echo "Installing PG17 packages from offline dir: $PG17_LOCAL_DIR"
        sudo dnf install -y --nogpgcheck $PG17_LOCAL_DIR/*.rpm
    else
        echo "Installing PG17 packages from PGDG repo"
        dnf_install $pkgs
    fi
}

if [ "$POSTGRESQL_MODE" = "local" ]; then
    echo -e "\n---- Installing PostgreSQL 17 Server locally ----"
    install_pg17_packages postgresql17 postgresql17-server postgresql17-contrib postgresql17-devel
    sudo /usr/pgsql-17/bin/postgresql-17-setup initdb
    sudo systemctl start postgresql-17
    sudo systemctl enable postgresql-17
    PG_BIN_PATH="/usr/pgsql-17/bin"

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
    # Remote PostgreSQL - only need client libs + devel for psycopg2 build
    echo -e "\n---- Installing PostgreSQL 17 client libs only (remote DB) ----"
    install_pg17_packages postgresql17-libs postgresql17-devel postgresql17
    PG_BIN_PATH="/usr/pgsql-17/bin"
fi

# Add psql/pg_config to PATH and ensure symlinks exist
if [ "$PG_BIN_PATH" != "/usr/bin" ]; then
    echo "export PATH=${PG_BIN_PATH}:\$PATH" | sudo tee /etc/profile.d/postgresql.sh
    export PATH=${PG_BIN_PATH}:$PATH

    # Create symlinks so pg_config is always findable (even inside sudo)
    [ -f "${PG_BIN_PATH}/pg_config" ] && sudo ln -sf ${PG_BIN_PATH}/pg_config /usr/bin/pg_config
    [ -f "${PG_BIN_PATH}/psql" ] && sudo ln -sf ${PG_BIN_PATH}/psql /usr/bin/psql
fi

# Verify pg_config is findable
which pg_config >/dev/null 2>&1 || echo "WARN: pg_config not in PATH. psycopg2 build will fail."

#--------------------------------------------------
# Install System Dependencies
#--------------------------------------------------
echo -e "\n---- Installing Python 3 + pip3 ----"
dnf_install python3 python3-pip python3-devel python3-setuptools python3-wheel

echo -e "\n---- Installing system dependencies ----"
# Core dependencies (always available in RHEL BaseOS + AppStream)
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
    openldap-devel \
    cyrus-sasl-devel \
    openssl-devel \
    libffi-devel \
    zlib-devel \
    redhat-rpm-config \
    xorg-x11-fonts-Type1 \
    xorg-x11-fonts-75dpi

# Optional dependencies (CRB/EPEL - may not be available without subscription)
dnf_install libzip-devel 2>/dev/null || echo "WARN: libzip-devel not available (needs CRB/EPEL). Skipping — not required for core Odoo."

echo -e "\n---- Install Python packages / Odoo 19 requirements ----"
# Try local requirements.txt first (when GitHub is blocked)
if [ -f "$OE_LOCAL_REQUIREMENTS" ]; then
    echo "Using local requirements file: $OE_LOCAL_REQUIREMENTS"
    pip_install -r "$OE_LOCAL_REQUIREMENTS"
elif [ -f "$OE_HOME_EXT/requirements.txt" ]; then
    echo "Using requirements.txt from Odoo source"
    pip_install -r "$OE_HOME_EXT/requirements.txt"
else
    echo "Downloading requirements.txt from GitHub"
    pip_install -r "https://github.com/odoo/odoo/raw/${OE_VERSION}/requirements.txt" || \
        { echo "ERROR: Cannot download requirements.txt. Upload it to $OE_LOCAL_REQUIREMENTS"; exit 1; }
fi

# Ensure phonenumbers is installed
pip_install phonenumbers

echo -e "\n---- Installing Node.js, npm and rtlcss for LTR support ----"
# Install Node.js from RHEL AppStream (NodeSource fallback skipped - external)
dnf_install nodejs npm 2>/dev/null || echo "INFO: nodejs/npm not in AppStream. RTL (rtlcss) will be skipped."

if command -v node >/dev/null 2>&1; then
    echo -e "---- Node.js version: $(node --version 2>/dev/null) ----"
    echo -e "---- npm version: $(npm --version 2>/dev/null) ----"

    # rtlcss is only needed for RTL (right-to-left) languages
    # Skip gracefully if npm registry is blocked by proxy
    timeout 60 sudo npm install -g rtlcss 2>/dev/null || \
        echo "INFO: rtlcss install failed (npm registry blocked). RTL support disabled."
else
    echo "INFO: Node.js not available. Skipping rtlcss install."
fi

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

    # Check if a local RPM was uploaded manually (for GitHub-blocked environments)
    LOCAL_WKHTML_RPM="/tmp/wkhtmltox.rpm"

    if [ -f "$LOCAL_WKHTML_RPM" ] && [ -s "$LOCAL_WKHTML_RPM" ]; then
        echo -e "---- Using locally uploaded wkhtmltopdf RPM: $LOCAL_WKHTML_RPM ----"
        sudo dnf localinstall -y --nogpgcheck "$LOCAL_WKHTML_RPM" 2>/dev/null || \
        sudo rpm -Uvh --nodeps "$LOCAL_WKHTML_RPM" 2>/dev/null || true
    elif [ -n "$WKHTML_RPM" ]; then
        echo -e "---- Downloading wkhtmltopdf RPM from GitHub ----"
        timeout 30 curl -fsSL "$WKHTML_RPM" -o /tmp/wkhtmltox.rpm 2>/dev/null

        if [ -f /tmp/wkhtmltox.rpm ] && [ -s /tmp/wkhtmltox.rpm ]; then
            echo -e "---- Installing wkhtmltopdf RPM ----"
            sudo dnf localinstall -y --nogpgcheck /tmp/wkhtmltox.rpm 2>/dev/null || \
            sudo rpm -Uvh --nodeps /tmp/wkhtmltox.rpm 2>/dev/null || true
            rm -f /tmp/wkhtmltox.rpm
        else
            echo ""
            echo "WARNING: Could not download wkhtmltopdf (github.com may be blocked)."
            echo "To install manually:"
            echo "  1. On a machine with internet, download:"
            echo "     $WKHTML_RPM"
            echo "  2. Upload to this server at: $LOCAL_WKHTML_RPM"
            echo "  3. Re-run this script, or run:"
            echo "     sudo dnf localinstall -y --nogpgcheck $LOCAL_WKHTML_RPM"
        fi
    else
        echo -e "---- Unsupported architecture for wkhtmltopdf: $ARCH ----"
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
# Create ODOO system user (skip if already exists)
#--------------------------------------------------
if id "$OE_USER" >/dev/null 2>&1; then
    echo -e "\n---- User '$OE_USER' already exists, skipping user creation ----"
else
    echo -e "\n---- Creating ODOO system user '$OE_USER' ----"
    sudo adduser --system --shell=/bin/bash --home-dir=$OE_HOME --user-group $OE_USER 2>/dev/null || \
    sudo useradd --system --shell /bin/bash --home-dir $OE_HOME --create-home --user-group $OE_USER 2>/dev/null || \
    { echo "ERROR: Could not create user $OE_USER. Create it manually or set OE_USER to an existing user."; exit 1; }
fi

# Ensure OE_HOME exists and is owned by OE_USER (covers case where user existed before)
sudo mkdir -p $OE_HOME
sudo chown $OE_USER:$OE_USER $OE_HOME

echo -e "\n---- Create Log directory ----"
sudo mkdir -p /var/log/$OE_USER
sudo chown $OE_USER:$OE_USER /var/log/$OE_USER

#--------------------------------------------------
# Install ODOO 19
#--------------------------------------------------
echo -e "\n==== Installing ODOO 19 Server ===="

if [ -f "$OE_HOME_EXT/odoo-bin" ]; then
    echo "---- Odoo source already installed at $OE_HOME_EXT, skipping ----"
elif [ -n "$OE_LOCAL_SOURCE" ] && [ -f "$OE_LOCAL_SOURCE" ]; then
    echo "---- Extracting Odoo source from $OE_LOCAL_SOURCE ----"
    dnf_install unzip 2>/dev/null || true
    sudo mkdir -p $OE_HOME_EXT
    # Extract to a tmp dir and move contents to avoid double-nesting
    TMP_EXTRACT=$(mktemp -d)
    sudo unzip -q "$OE_LOCAL_SOURCE" -d "$TMP_EXTRACT"
    # GitHub zips contain a single top-level folder like odoo-19.0/
    INNER_DIR=$(sudo find "$TMP_EXTRACT" -maxdepth 1 -mindepth 1 -type d | head -n 1)
    if [ -n "$INNER_DIR" ]; then
        sudo cp -a "$INNER_DIR"/. "$OE_HOME_EXT/"
    fi
    sudo rm -rf "$TMP_EXTRACT"
    echo "---- Odoo source extracted to $OE_HOME_EXT ----"
else
    echo "---- No local source provided, attempting git clone from GitHub ----"
    sudo git config --global --add safe.directory $OE_HOME_EXT
    sudo git config --global --add safe.directory "$OE_HOME/enterprise/addons"
    if [ -n "$http_proxy" ]; then
        sudo git config --global http.proxy "$http_proxy"
        sudo git config --global https.proxy "${https_proxy:-$http_proxy}"
    fi

    if [ -d "$OE_HOME_EXT/.git" ]; then
        echo "---- Odoo git repo exists, pulling latest changes ----"
        sudo git -C $OE_HOME_EXT pull
    else
        sudo git clone --depth 1 --branch $OE_VERSION https://www.github.com/odoo/odoo $OE_HOME_EXT/ || \
            { echo "ERROR: Cannot clone from GitHub and no local source at $OE_LOCAL_SOURCE."; \
              echo "       Download https://github.com/odoo/odoo/archive/refs/heads/19.0.zip"; \
              echo "       and upload to $OE_LOCAL_SOURCE, then re-run this script."; \
              exit 1; }
    fi
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

    #----------------------------------------------
    # Generate self-signed SSL certificate (always)
    # This allows HTTPS to work immediately out of the box.
    # Replace later with Let's Encrypt or your own certificate.
    #----------------------------------------------
    SSL_CERT_DIR="/etc/ssl/odoo"
    SSL_CERT_FILE="${SSL_CERT_DIR}/odoo.crt"
    SSL_KEY_FILE="${SSL_CERT_DIR}/odoo.key"

    if [ ! -f "$SSL_CERT_FILE" ] || [ ! -f "$SSL_KEY_FILE" ]; then
        echo -e "\n---- Generating self-signed SSL certificate ----"
        sudo mkdir -p $SSL_CERT_DIR
        sudo openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
            -keyout $SSL_KEY_FILE \
            -out $SSL_CERT_FILE \
            -subj "/C=SA/ST=Riyadh/L=Riyadh/O=Odoo/OU=IT/CN=${WEBSITE_NAME}"
        sudo chmod 600 $SSL_KEY_FILE
        sudo chmod 644 $SSL_CERT_FILE
        echo "Self-signed certificate generated at $SSL_CERT_DIR"
    else
        echo "SSL certificate already exists at $SSL_CERT_DIR, skipping generation."
    fi

    #----------------------------------------------
    # Try to get Let's Encrypt certificate if domain is configured
    #----------------------------------------------
    USE_LETSENCRYPT="False"
    if [ "$ENABLE_SSL" = "True" ] && [ "$ADMIN_EMAIL" != "odoo@example.com" ] && [ "$WEBSITE_NAME" != "_" ]; then
        echo -e "\n---- Attempting Let's Encrypt certificate ----"

        # Write temp HTTP config for Certbot challenge
        sudo bash -c "cat > /etc/nginx/conf.d/${OE_CONFIG}.conf" <<TMPEOF
server {
    listen 80;
    server_name ${WEBSITE_NAME};
    location / { proxy_pass http://127.0.0.1:${OE_PORT}; }
}
TMPEOF
        sudo systemctl enable nginx
        sudo systemctl start nginx
        sudo systemctl reload nginx

        dnf_install certbot python3-certbot-nginx
        sudo certbot certonly --nginx -d $WEBSITE_NAME --noninteractive --agree-tos --email $ADMIN_EMAIL 2>/dev/null

        if [ -f "/etc/letsencrypt/live/$WEBSITE_NAME/fullchain.pem" ]; then
            SSL_CERT_FILE="/etc/letsencrypt/live/$WEBSITE_NAME/fullchain.pem"
            SSL_KEY_FILE="/etc/letsencrypt/live/$WEBSITE_NAME/privkey.pem"
            USE_LETSENCRYPT="True"
            echo "Let's Encrypt certificate obtained successfully!"

            # Set up auto-renewal cron
            (sudo crontab -l 2>/dev/null; echo "0 0,12 * * * certbot renew --quiet --post-hook 'systemctl reload nginx'") | sudo crontab - 2>/dev/null || true
        else
            echo "Let's Encrypt failed (DNS may not point here yet)."
            echo "Using self-signed certificate. You can switch later."
        fi
    fi

    #----------------------------------------------
    # Write final HTTPS Nginx config
    #----------------------------------------------
    echo -e "\n---- Writing HTTPS Nginx config ----"
    sudo bash -c "cat > /etc/nginx/conf.d/${OE_CONFIG}.conf" <<NGINXEOF
# Odoo backend upstream
upstream odoo {
    server 127.0.0.1:${OE_PORT};
}

# Odoo gevent upstream (websocket)
upstream odoochat {
    server 127.0.0.1:${LONGPOLLING_PORT};
}

# Required for websocket upgrade (must be at http context level)
map \$http_upgrade \$connection_upgrade {
    default upgrade;
    ''      close;
}

# HTTP -> HTTPS redirect
server {
    listen 80;
    server_name ${WEBSITE_NAME};
    return 301 https://\$host\$request_uri;
}

# HTTPS server
server {
    listen 443 ssl http2;
    server_name ${WEBSITE_NAME};

    # SSL certificates
    # To switch to Let's Encrypt later, run:
    #   sudo certbot certonly --nginx -d ${WEBSITE_NAME}
    # Then replace the paths below with:
    #   ssl_certificate /etc/letsencrypt/live/${WEBSITE_NAME}/fullchain.pem;
    #   ssl_certificate_key /etc/letsencrypt/live/${WEBSITE_NAME}/privkey.pem;
    ssl_certificate ${SSL_CERT_FILE};
    ssl_certificate_key ${SSL_KEY_FILE};
    ssl_session_timeout 30m;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384;
    ssl_prefer_server_ciphers off;

    # Timeouts
    proxy_read_timeout 720s;
    proxy_connect_timeout 720s;
    proxy_send_timeout 720s;

    # Log files
    access_log /var/log/nginx/${OE_USER}-access.log;
    error_log  /var/log/nginx/${OE_USER}-error.log;

    # Request limits
    client_max_body_size 0;

    # Redirect websocket requests to odoo gevent port
    location /websocket {
        proxy_pass http://odoochat;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
        proxy_set_header X-Forwarded-Host \$http_host;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Real-IP \$remote_addr;

        add_header Strict-Transport-Security "max-age=31536000; includeSubDomains";
        proxy_cookie_flags session_id samesite=lax secure;
    }

    # Redirect requests to odoo backend server
    location / {
        proxy_pass http://odoo;
        proxy_redirect off;
        proxy_set_header X-Forwarded-Host \$http_host;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Real-IP \$remote_addr;

        add_header Strict-Transport-Security "max-age=31536000; includeSubDomains";
        proxy_cookie_flags session_id samesite=lax secure;
    }

    # Common gzip
    gzip_types text/css text/scss text/plain text/xml application/xml application/json application/javascript;
    gzip on;
}
NGINXEOF

    # Start / reload Nginx
    sudo systemctl enable nginx
    sudo systemctl start nginx
    sudo nginx -t && sudo systemctl reload nginx

    echo "Nginx configured with HTTPS. File: /etc/nginx/conf.d/${OE_CONFIG}.conf"
    if [ "$USE_LETSENCRYPT" = "True" ]; then
        echo "  Certificate: Let's Encrypt (auto-renewal enabled)"
    else
        echo "  Certificate: Self-signed ($SSL_CERT_DIR)"
        echo ""
        echo "  To switch to Let's Encrypt later:"
        echo "    1. Point your domain DNS to this server"
        echo "    2. Run: sudo certbot certonly --nginx -d YOUR_DOMAIN"
        echo "    3. Edit /etc/nginx/conf.d/${OE_CONFIG}.conf"
        echo "       Replace ssl_certificate and ssl_certificate_key paths with:"
        echo "         /etc/letsencrypt/live/YOUR_DOMAIN/fullchain.pem"
        echo "         /etc/letsencrypt/live/YOUR_DOMAIN/privkey.pem"
        echo "    4. Run: sudo nginx -t && sudo systemctl reload nginx"
    fi
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
    echo " HTTPS:                 Enabled (https://$WEBSITE_NAME)"
    echo " SSL certificate:       $SSL_CERT_FILE"
    echo " SSL key:               $SSL_KEY_FILE"
fi
echo ""
echo " SELinux: If you have issues, check:"
echo "   sudo audit2why -a"
echo "   sudo sealert -a /var/log/audit/audit.log"
echo ""
echo " Firewall: Ports $OE_PORT and $LONGPOLLING_PORT are open."
echo "============================================================"
