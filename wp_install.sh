#!/bin/bash

# ==============================================================================
# 全自动 WordPress LEMP + 灵活 SSL 安装脚本 (修正版)
# Fully Automated WordPress on LEMP + Flexible SSL Installer (Multi-Distro) (Revised)
#
# Author: logover
# Version: 1.3
# Description: 自动检测操作系统 (Debian/Ubuntu, RHEL/CentOS/Fedora, Arch) 并安装
#              WordPress LEMP 环境。使用 WP-CLI 跳过网页安装，提供灵活的 SSL
#              选项和中文安装选项。
# ==============================================================================

# --- 全局错误处理 / Global Error Handling ---
# 任何命令失败时立即退出，并打印错误信息。
set -e
trap 'error "脚本在行 $LINENO 发生错误。/ Script error on line $LINENO."' ERR

# --- 颜色定义 / Color Definitions ---
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# --- 全局变量 / Global Variables ---
CONFIG_FILE="/etc/wordpress_installer/config.conf"
# OS-specific variables will be set by detect_os_and_set_vars
PKG_CMD_UPDATE=""
PKG_CMD_INSTALL=""
PKG_CMD_PURGE=""
REQUIRED_PACKAGES=""
WEB_USER=""
# PHP_FPM_SERVICE 和 PHP_FPM_SOCK_PATH 在 detect_os_and_set_vars 中设定默认值
# 并在 install_wordpress 中根据实际 PHP 版本进一步确定
PHP_FPM_SERVICE=""
PHP_FPM_SOCK_PATH=""
NGINX_FASTCGI_INCLUDE="" # Will be set based on OS for Nginx PHP config
PHP_VERSION="" # Track PHP version globally if needed later

# --- 功能函数：打印不同颜色的信息 / Function to print messages ---
info() {
    echo -e "${GREEN}[信息/INFO] $1${NC}"
}

warn() {
    echo -e "${YELLOW}[警告/WARN] $1${NC}"
}

error() {
    echo -e "${RED}[错误/ERROR] $1${NC}"
    exit 1
}

# --- 功能函数：检查 root 权限 / Function to check for root privileges ---
check_root() {
    if [ "$EUID" -ne 0 ]; then
        error "此脚本必须以 root 权限运行。/ This script must be run as root. Please use 'sudo'."
    fi
}

# --- 功能函数：确保使用 bash 运行 / Function to ensure script is run with bash ---
ensure_bash() {
    if [ -z "$BASH_VERSION" ]; then
        error "此脚本必须使用 bash 运行，但检测到您可能正在使用 sh。请通过 'sudo bash $0' 来运行。\nThis script must be run with bash. Please run it using 'sudo bash $0'."
    fi
}

# --- 功能函数：检测操作系统并设置对应变量 / Function to detect OS and set variables ---
# 此函数不再执行任何安装，仅设定包管理命令和通用包名/用户等。
detect_os_and_set_vars() {
    info "正在检测操作系统... / Detecting operating system..."
    local OS_ID_LIKE=""

    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS_ID=$ID
        OS_ID_LIKE=$ID_LIKE
    else
        error "无法检测操作系统，/etc/os-release 文件不存在。/ Cannot detect OS, /etc/os-release not found."
    fi

    info "检测到操作系统为: $OS_ID (家族: $OS_ID_LIKE) / Detected OS: $OS_ID (Family: $OS_ID_LIKE)"

    case "$OS_ID" in
        ubuntu|debian)
            PKG_CMD_UPDATE="apt-get update -y"
            PKG_CMD_INSTALL="apt-get install -y"
            PKG_CMD_PURGE="apt-get purge --auto-remove -y"
            # 注意：php-fpm 在此不包含版本，版本将在安装前动态确定
            REQUIRED_PACKAGES="nginx mariadb-server php-fpm php-mysql php-curl php-gd php-mbstring php-xml php-xmlrpc php-soap php-intl php-zip php-imagick php-bcmath wget curl socat"
            WEB_USER="www-data"
            # 默认值，将在安装过程中根据实际PHP版本更新
            PHP_FPM_SERVICE="php-fpm"
            PHP_FPM_SOCK_PATH="/run/php/php-fpm.sock"
            NGINX_FASTCGI_INCLUDE="include snippets/fastcgi-php.conf;"
            ;;
        centos|rhel|fedora|rocky|almalinux)
            if command -v dnf &> /dev/null; then
                PKG_CMD_UPDATE="dnf check-update"
                PKG_CMD_INSTALL="dnf install -y"
                PKG_CMD_PURGE="dnf remove -y"
            elif command -v yum &> /dev/null; then
                PKG_CMD_UPDATE="yum check-update"
                PKG_CMD_INSTALL="yum install -y"
                PKG_CMD_PURGE="yum remove -y"
            else
                error "在 RHEL 系列系统上未找到 'dnf' 或 'yum'。/ Neither 'dnf' nor 'yum' found on RHEL-based system."
            fi
            warn "对于 RHEL/CentOS，建议启用 EPEL 和 Remi 源以获取最新的 PHP 版本。脚本将尝试使用系统默认源。/ For RHEL/CentOS, enabling EPEL and Remi repositories is recommended for latest PHP versions. The script will try to use default repos."
            REQUIRED_PACKAGES="nginx mariadb-server php-fpm php-mysqlnd php-curl php-gd php-mbstring php-xml php-xmlrpc php-soap php-intl php-zip php-pecl-imagick php-bcmath wget curl socat"
            WEB_USER="nginx"
            PHP_FPM_SERVICE="php-fpm"
            PHP_FPM_SOCK_PATH="/var/run/php-fpm/www.sock" # Common path for RHEL-based systems
            NGINX_FASTCGI_INCLUDE="" # Handled inline for RHEL/CentOS
            ;;
        arch)
            PKG_CMD_UPDATE="pacman -Syu"
            PKG_CMD_INSTALL="pacman -S --noconfirm"
            PKG_CMD_PURGE="pacman -Rns --noconfirm"
            REQUIRED_PACKAGES="nginx mariadb php php-fpm php-gd php-intl php-imagick wget curl socat"
            WEB_USER="http"
            PHP_FPM_SERVICE="php-fpm"
            PHP_FPM_SOCK_PATH="/run/php-fpm/php-fpm.sock"
            NGINX_FASTCGI_INCLUDE="include /etc/nginx/fastcgi.conf;" # Common for Arch
            ;;
        *)
            error "不支持的操作系统: $OS_ID. / Unsupported operating system: $OS_ID."
            ;;
    esac
    # PHP_VERSION 不在此处设置，因为php命令可能尚未可用。
    # 它将在 install_wordpress 函数中在安装完所有包后设置。
}


# ==============================================================================
# 安装逻辑 / INSTALLATION LOGIC
# ==============================================================================
install_wordpress() {
    info "开始全自动 WordPress + 灵活 SSL 安装... / Starting Fully Automated WordPress + Flexible SSL installation..."

    # --- 1. 收集所有必要信息 / Gather All Necessary Information ---
    local domain admin_email site_title admin_user admin_pass admin_pass_confirm db_name db_user db_pass db_pass_confirm WP_PATH ssl_email

    read -p "请输入您的域名 (例如 example.com) / Please enter your domain name (e.g., example.com): " domain
    if [ -z "$domain" ]; then error "域名不能为空。/ Domain name cannot be empty."; fi
    
    ssl_email="admin@$domain" # default, can be overridden by acme.sh prompt if needed

    read -p "请输入 WordPress 管理员邮箱 / Please enter the WordPress admin email: " admin_email
    if [ -z "$admin_email" ]; then error "WordPress 管理员邮箱不能为空。/ WordPress admin email cannot be empty."; fi
    
    read -p "请输入 WordPress 站点标题 / Please enter a title for your WordPress site: " site_title
    if [ -z "$site_title" ]; then error "站点标题不能为空。/ Site title cannot be empty."; fi
    
    read -p "请输入 WordPress 管理员用户名 / Please enter a username for the WordPress admin: " admin_user
    if [ -z "$admin_user" ]; then error "管理员用户名不能为空。/ Admin username cannot be empty."; fi
    
    while true; do
        read -sp "请输入 WordPress 管理员密码 / Please enter a password for the WP admin: " admin_pass
        echo
        read -sp "确认管理员密码 / Confirm admin password: " admin_pass_confirm
        echo
        [ "$admin_pass" = "$admin_pass_confirm" ] && [ -n "$admin_pass" ] && break
        warn "密码不匹配或为空，请重试。/ Passwords do not match or are empty. Please try again."
    done
    
    info "现在，请输入数据库信息。/ Now, please enter the database information."
    read -p "请输入 WordPress 数据库名称 / Please enter the WordPress database name: " db_name
    if [ -z "$db_name" ]; then error "数据库名称不能为空。/ Database name cannot be empty."; fi
    
    read -p "请输入数据库用户名 / Please enter the database username: " db_user
    if [ -z "$db_user" ]; then error "数据库用户名不能为空。/ Database username cannot be empty."; fi
    
    while true; do
        read -sp "请输入数据库用户的密码 / Please enter a password for the database user: " db_pass
        echo
        read -sp "确认密码 / Confirm password: " db_pass_confirm
        echo
        [ "$db_pass" = "$db_pass_confirm" ] && [ -n "$db_pass" ] && break
        warn "密码不匹配或为空，请重试。/ Passwords do not match or are empty. Please try again."
    done

    WP_PATH="/var/www/$domain"

    # --- 2. 更新系统并安装软件包 / Update System and Install Packages ---
    info "正在更新软件包列表... / Updating package lists..."
    $PKG_CMD_UPDATE || error "软件包列表更新失败！/ Package list update failed!"
    
    # 动态确定 PHP 版本和 FPM 服务名 (仅针对 Debian/Ubuntu)
    # 这一步必须在包安装之前执行，确保 REQUIRED_PACKAGES 包含正确的 PHP 版本包名
    if [[ "$OS_ID" == "ubuntu" || "$OS_ID" == "debian" ]]; then
        info "正在安装 php-cli 以确定 PHP 版本... / Installing php-cli to determine PHP version..."
        $PKG_CMD_INSTALL php-cli || error "安装 php-cli 失败！/ Failed to install php-cli!"
        
        # 确保 php 命令现在可用
        if ! command -v php &> /dev/null; then
            error "无法找到 'php' 命令，请手动安装 php-cli 后重试。/ 'php' command not found. Please install php-cli manually and try again."
        fi

        PHP_VERSION=$(php -r "echo PHP_MAJOR_VERSION . '.' . PHP_MINOR_VERSION;")
        PHP_FPM_SERVICE="php${PHP_VERSION}-fpm"
        # 替换 REQUIRED_PACKAGES 中的通用 php-fpm 为带版本号的
        REQUIRED_PACKAGES=$(echo "$REQUIRED_PACKAGES" | sed "s/php-fpm/$PHP_FPM_SERVICE/")
        info "检测到 PHP 版本: ${PHP_VERSION}, PHP-FPM 服务名为: ${PHP_FPM_SERVICE}"
    else
        # 对于非 Debian/Ubuntu 系统，PHP_VERSION 可以在 PHP 安装后获得
        # 在这里初始化，稍后在配置 PHP.ini 时再获取
        PHP_VERSION="unknown"
    fi

    info "正在安装所需软件包... / Installing required packages..."
    $PKG_CMD_INSTALL $REQUIRED_PACKAGES
    info "软件包安装成功。/ Packages installed successfully."

    # --- 2b. 安装 WP-CLI / Install WP-CLI ---
    if ! command -v wp &> /dev/null; then
        info "正在安装 WP-CLI... / Installing WP-CLI..."
        curl -sO https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar
        chmod +x wp-cli.phar
        mv wp-cli.phar /usr/local/bin/wp
        info "WP-CLI 安装成功。/ WP-CLI installed successfully."
    else
        info "WP-CLI 已安装。/ WP-CLI is already installed."
    fi

    # --- 3. 配置 LEMP 核心服务 / Configure Core LEMP Services ---
    info "正在启动并启用 MariaDB 和 PHP-FPM 服务... / Starting and enabling MariaDB & PHP-FPM services..."
    systemctl start mariadb || error "启动 MariaDB 失败！/ Failed to start MariaDB!"
    systemctl enable mariadb || error "启用 MariaDB 失败！/ Failed to enable MariaDB!"
    systemctl start "$PHP_FPM_SERVICE" || error "启动 $PHP_FPM_SERVICE 失败！/ Failed to start $PHP_FPM_SERVICE!"
    systemctl enable "$PHP_FPM_SERVICE" || error "启用 $PHP_FPM_SERVICE 失败！/ Failed to enable $PHP_FPM_SERVICE!"
    
    info "正在配置 PHP 上传及内存限制... / Configuring PHP upload & memory limits..."
    # 确保 PHP_VERSION 在此处可用，对于非 Debian/Ubuntu 系统，这里获取它
    if [[ "$OS_ID" != "ubuntu" && "$OS_ID" != "debian" ]]; then
        PHP_VERSION=$(php -r "echo PHP_MAJOR_VERSION . '.' . PHP_MINOR_VERSION;") || warn "无法获取 PHP 版本，可能影响 php.ini 路径查找。/ Could not get PHP version, may affect php.ini path."
    fi

    # Find php.ini path more robustly for the FPM service
    local PHP_INI_PATH=""
    if [[ "$OS_ID" == "ubuntu" || "$OS_ID" == "debian" ]]; then
        PHP_INI_PATH="/etc/php/$PHP_VERSION/fpm/php.ini"
    elif [[ "$OS_ID" == "centos" || "$OS_ID" == "rhel" || "$OS_ID" == "fedora" || "$OS_ID" == "rocky" || "$OS_ID" == "almalinux" ]]; then
        # CentOS/RHEL/AlmaLinux/Rocky 上的 php.ini 路径
        PHP_INI_PATH="/etc/php.ini" # 尝试默认路径
        if [ ! -f "$PHP_INI_PATH" ]; then # 尝试通过 find 查找更具体的路径
            PHP_INI_PATH=$(find /etc/php -name "php.ini" -path "*/fpm/php.ini" 2>/dev/null | head -n 1)
        fi
    elif [[ "$OS_ID" == "arch" ]]; then
        PHP_INI_PATH="/etc/php/php.ini"
    fi

    if [ -z "$PHP_INI_PATH" ] || [ ! -f "$PHP_INI_PATH" ]; then
        warn "无法自动定位 php.ini 文件，跳过 PHP 限制配置。 / Could not auto-locate php.ini, skipping PHP limit configuration."
    else
        info "找到 php.ini 文件: $PHP_INI_PATH"
        sed -i "s/^\s*;*\s*upload_max_filesize\s*=\s*.*/upload_max_filesize = 128M/" "$PHP_INI_PATH" || warn "设置 upload_max_filesize 失败。/ Failed to set upload_max_filesize."
        sed -i "s/^\s*;*\s*post_max_size\s*=\s*.*/post_max_size = 128M/" "$PHP_INI_PATH" || warn "设置 post_max_size 失败。/ Failed to set post_max_size."
        sed -i "s/^\s*;*\s*memory_limit\s*=\s*.*/memory_limit = 256M/" "$PHP_INI_PATH" || warn "设置 memory_limit 失败。/ Failed to set memory_limit."
        systemctl restart "$PHP_FPM_SERVICE" || error "重启 $PHP_FPM_SERVICE 失败！/ Failed to restart $PHP_FPM_SERVICE!"
    fi

    info "正在配置 MariaDB 数据库和用户... / Configuring MariaDB database and user..."
    local DB_EXISTS
    DB_EXISTS=$(mysql -u root -e "SHOW DATABASES LIKE '$db_name';" | grep "$db_name" > /dev/null && echo "0" || echo "1")
    if [ "$DB_EXISTS" -eq 0 ]; then
        warn "数据库 '$db_name' 已存在。/ Database '$db_name' already exists."
        read -p "您想删除它并创建一个全新的吗？(y/N) / Do you want to delete it and create a new one? (y/N): " delete_db
        if [[ "$delete_db" == "y" || "$delete_db" == "Y" ]]; then
            info "正在删除现有数据库... / Deleting existing database..."
            mysql -u root -e "DROP DATABASE \`$db_name\`;" || error "删除数据库失败！/ Failed to drop database!"
        else
            error "用户选择不删除现有数据库，安装中止。/ User chose not to delete the database. Installation aborted."
        fi
    fi
    
    mysql -u root <<MYSQL_SCRIPT
DROP USER IF EXISTS '$db_user'@'localhost';
CREATE DATABASE \`$db_name\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER '$db_user'@'localhost' IDENTIFIED BY '$db_pass';
GRANT ALL PRIVILEGES ON \`$db_name\`.* TO '$db_user'@'localhost';
FLUSH PRIVILEGES;
MYSQL_SCRIPT
    info "MariaDB 数据库和用户配置成功。/ MariaDB database and user configured successfully."
    warn "建议运行 'sudo mysql_secure_installation' 来提高数据库安全性。/ It's recommended to run 'sudo mysql_secure_installation' for better database security."


    # --- 4. 配置 WordPress (文件和数据库) / Configure WordPress (Files & Database) ---
    info "正在创建并准备 WordPress 目录 $WP_PATH... / Creating and preparing WordPress directory $WP_PATH..."
    mkdir -p "$WP_PATH" || error "创建 WordPress 目录失败！/ Failed to create WordPress directory!"

    if [ "$(ls -A "$WP_PATH" 2>/dev/null)" ]; then
        warn "目录 $WP_PATH 不是空的。/ Directory $WP_PATH is not empty."
        read -p "您想清空它并继续安装吗？(这会删除里面的所有文件！) (y/N) / Do you want to empty it and continue? (This will delete all files inside!) (y/N): " clear_dir
        if [[ "$clear_dir" == "y" || "$clear_dir" == "Y" ]]; then
            info "正在清空目录... / Emptying directory..."
            rm -rf "$WP_PATH"/* || error "清空目录失败！/ Failed to empty directory!"
        else
            error "用户选择不清空目录，安装中止。/ User chose not to empty the directory. Installation aborted."
        fi
    fi

    info "正在下载 WordPress... / Downloading WordPress..."
    cd /tmp
    wget -q https://wordpress.org/latest.tar.gz -O wordpress.tar.gz || error "下载 WordPress 压缩包失败！/ Failed to download WordPress archive!"

    info "正在解压 WordPress... / Extracting WordPress..."
    tar -xzf wordpress.tar.gz -C "$WP_PATH" --strip-components=1 || error "解压 WordPress 失败！/ Failed to extract WordPress!"
    rm wordpress.tar.gz

    # Use OS-specific web user for permissions
    chown -R "$WEB_USER:$WEB_USER" "$WP_PATH" || error "设置文件所有者失败！/ Failed to set file ownership!"
    find "$WP_PATH" -type d -exec chmod 755 {} \; || error "设置目录权限失败！/ Failed to set directory permissions!"
    find "$WP_PATH" -type f -exec chmod 644 {} \; || error "设置文件权限失败！/ Failed to set file permissions!"

    info "正在通过 WP-CLI 完成核心安装... / Running core install with WP-CLI..."
    # Use OS-specific web user
    sudo -u "$WEB_USER" wp config create --path="$WP_PATH" --dbname="$db_name" --dbuser="$db_user" --dbpass="$db_pass" --dbcharset="utf8mb4" --quiet || error "使用 WP-CLI 创建 wp-config.php 失败！请检查数据库连接信息。/ Failed to create wp-config.php!"

    info "正在安装 WordPress 核心 (英文版)..."
    sudo -u "$WEB_USER" wp core install --path="$WP_PATH" --url="http://$domain" --title="$site_title" --admin_user="$admin_user" --admin_password="$admin_pass" --admin_email="$admin_email" --skip-email || error "使用 WP-CLI 安装 WordPress 核心失败！/ Failed to install WordPress core using WP-CLI!"

    read -p "是否需要为 WordPress 安装并激活简体中文? (y/N) / Install and activate Chinese (Simplified) for WordPress? (y/N): " install_chinese
    if [[ "$install_chinese" == "y" || "$install_chinese" == "Y" ]]; then
        info "正在准备语言目录... / Preparing languages directory..."
        sudo -u "$WEB_USER" mkdir -p "$WP_PATH/wp-content/languages" || warn "创建语言目录失败。/ Failed to create languages directory."
        info "正在下载并安装简体中文语言包... / Downloading and installing Chinese (Simplified) language pack..."
        sudo -u "$WEB_USER" wp language core install zh_CN --path="$WP_PATH" || warn "下载中文语言包失败。/ Failed to download Chinese language pack."
        
        if [ $? -eq 0 ]; then # Check if previous command succeeded
            info "正在激活简体中文... / Activating Chinese (Simplified)..."
            sudo -u "$WEB_USER" wp site switch-language zh_CN --path="$WP_PATH" || warn "激活中文语言失败。/ Failed to activate Chinese language."
            info "简体中文已激活。/ Chinese (Simplified) has been activated."
        else
            warn "由于中文语言包下载失败，跳过中文激活。/ Skipping Chinese activation due to language pack download failure."
        fi
    else
        info "已跳过中文安装。/ Skipped Chinese language installation."
    fi

    info "正在根据系统设置 WordPress 时区... / Setting WordPress timezone from system..."
    local SYSTEM_TIMEZONE
    SYSTEM_TIMEZONE=$(timedatectl show --property=Timezone --value 2>/dev/null)
    if [ -n "$SYSTEM_TIMEZONE" ]; then
        sudo -u "$WEB_USER" wp option update timezone_string "$SYSTEM_TIMEZONE" --path="$WP_PATH" || warn "设置 WordPress 时区失败。/ Failed to set WordPress timezone."
    else
        warn "无法获取系统时区，跳过 WordPress 时区设置。/ Could not get system timezone, skipping WordPress timezone setting."
    fi
    info "WordPress 核心安装已通过命令行完成！/ WordPress core installation via CLI is complete!"

    # --- 5. SSL证书配置 / SSL Certificate Configuration ---
    local NGINX_CONF_PATH="/etc/nginx/conf.d/${domain}.conf"
    if [ -f /etc/nginx/sites-enabled/default ]; then rm -f /etc/nginx/sites-enabled/default; fi # Debian/Ubuntu specific, but safe elsewhere
    local site_protocol="http"
    local ACME_CMD=""
    local ACME_HOME_DIR=""
    local found_acme_cert_type=""
    local cert_path=""
    local key_path=""
    local is_ecc=false
    
    info "正在检测已有的 SSL 证书... / Detecting existing SSL certificates..."
    local potential_acme_execs=("acme.sh" "acme")
    for cmd in "${potential_acme_execs[@]}"; do
        if command -v "$cmd" &> /dev/null; then
            ACME_CMD=$(command -v "$cmd")
            info "检测到 acme 工具: $ACME_CMD"
            break
        fi
    done
    
    local potential_acme_homes=("/root/.acme.sh" "/etc/acme.sh" "/var/lib/acme" "$HOME/.acme.sh")
    for home in "${potential_acme_homes[@]}"; do
        if [ -d "$home" ] && [ -f "$home/account.conf" ]; then
            ACME_HOME_DIR=$home
            info "检测到 acme 主目录: $ACME_HOME_DIR"
            if [ -z "$ACME_CMD" ] && [ -f "$home/acme.sh" ]; then
                ACME_CMD="$home/acme.sh" # Fallback if not in PATH
            fi
            break
        fi
    done

    if [ -n "$ACME_HOME_DIR" ]; then
        local potential_dirs=($(find "$ACME_HOME_DIR" -maxdepth 1 -type d -name "$domain*" 2>/dev/null))
        for dir in "${potential_dirs[@]}"; do
            if [ -f "$dir/$domain.key" ] && [ -f "$dir/fullchain.cer" ]; then
                if [[ "$dir" == *"_ecc" ]]; then
                    found_acme_cert_type="ECC"
                else
                    found_acme_cert_type="RSA"
                fi
                break
            fi
        done
    fi

    local found_certbot_cert=false
    if command -v certbot &> /dev/null; then
        local certbot_live_dir="/etc/letsencrypt/live/$domain"
        if [ -d "$certbot_live_dir" ]; then
            if [ -f "$certbot_live_dir/privkey.pem" ] && [ -f "$certbot_live_dir/fullchain.pem" ]; then
                found_certbot_cert=true
            fi
        fi
    fi

    local options=()
    if [ "$found_acme_cert_type" == "ECC" ]; then options+=("使用已检测到的 acme.sh ECC 证书"); fi
    if [ "$found_acme_cert_type" == "RSA" ]; then options+=("使用已检测到的 acme.sh RSA 证书"); fi
    if [ "$found_certbot_cert" = true ]; then options+=("使用已检测到的 certbot 证书 ($domain)"); fi
    options+=("使用 acme.sh 申请新证书 (ECC)")
    options+=("手动提供已有证书路径")
    options+=("跳过SSL，仅使用 HTTP")
    options+=("退出安装")
    
    info "请选择您的 SSL 配置方案 / Please select your SSL configuration option:"
    local opt
    select opt in "${options[@]}"; do
        case $opt in
            "使用已检测到的 acme.sh ECC 证书") site_protocol="https"; is_ecc=true; break ;;
            "使用已检测到的 acme.sh RSA 证书") site_protocol="https"; is_ecc=false; break ;;
            "使用已检测到的 certbot 证书 ($domain)") 
                site_protocol="https"
                cert_path="/etc/letsencrypt/live/$domain/fullchain.pem"
                key_path="/etc/letsencrypt/live/$domain/privkey.pem"
                opt="手动提供已有证书路径" # Force this option for next logic block
                break 
                ;;
            "使用 acme.sh 申请新证书 (ECC)")
                site_protocol="https"
                is_ecc=true
                warn "自动申请证书需要确保您的域名 ($domain) 已正确解析到本服务器IP！"
                read -p "按回车键继续... / Press Enter to continue..."
                
                if [ -z "$ACME_CMD" ]; then
                    info "正在安装 acme.sh... / Installing acme.sh..."
                    # Check if email is needed for acme.sh initial install
                    if ! grep -q "DEFAULT_EMAIL" "$ACME_HOME_DIR/account.conf" 2>/dev/null; then
                        info "acme.sh 需要一个邮箱地址进行注册。/ acme.sh requires an email address for registration."
                        read -p "请输入 acme.sh 注册邮箱 (建议使用真实邮箱): " ssl_email
                        if [ -z "$ssl_email" ]; then error "acme.sh 注册邮箱不能为空。/ acme.sh registration email cannot be empty."; fi
                    fi
                    curl -s https://get.acme.sh | sh -s email="$ssl_email" || error "acme.sh 安装失败！/ acme.sh installation failed!"
                    ACME_HOME_DIR="/root/.acme.sh"
                    ACME_CMD="$ACME_HOME_DIR/acme.sh"
                fi
                
                # Source the environment script for acme.sh to be available in current shell
                # This needs to be done every time after acme.sh is installed or if the script is run in a new session.
                if [ -f "$ACME_HOME_DIR/acme.sh.env" ]; then
                    source "$ACME_HOME_DIR/acme.sh.env"
                else
                    error "acme.sh 环境脚本未找到：$ACME_HOME_DIR/acme.sh.env / acme.sh environment script not found: $ACME_HOME_DIR/acme.sh.env"
                fi

                info "正在配置 Nginx (HTTP) 以进行域名验证..."
                cat > "$NGINX_CONF_PATH" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name $domain;
    root $WP_PATH;
    location ~ /.well-known/acme-challenge/ { allow all; }
    location / { return 404; } # Important for security, prevent general HTTP access
}
EOF
                nginx -t && systemctl reload nginx || error "Nginx HTTP 配置或重载失败！/ Nginx HTTP config or reload failed!"
                
                info "正在使用 acme.sh 获取新的 ECC SSL 证书... / Obtaining new ECC SSL certificate with acme.sh..."
                # Use --debug 1 for more verbose output if issues occur
                "$ACME_CMD" --issue -d "$domain" -w "$WP_PATH" --ecc || error "使用acme.sh签发证书失败！/ Failed to issue cert with acme.sh!"
                break
                ;;
            "手动提供已有证书路径")
                site_protocol="https"
                if [ -z "$cert_path" ]; then # Only ask if not pre-filled by certbot option
                    read -ep "请输入您的证书文件 (fullchain) 的完整路径: " cert_path
                    read -ep "请输入您的私钥文件 (privkey) 的完整路径: " key_path
                fi
                if [ ! -f "$cert_path" ] || [ ! -f "$key_path" ]; then
                    error "提供的证书或私钥文件路径无效！/ Provided certificate or key file paths are invalid!"
                fi
                break
                ;;
            "跳过SSL，仅使用 HTTP") site_protocol="http"; break ;;
            "退出安装") error "用户选择退出安装。/ User chose to exit installation." ;;
            *) warn "无效选择，请重试。/ Invalid selection, please try again." ;;
        esac
    done

    # --- 5b. 根据选择配置最终的 Nginx / Configure Final Nginx Based on Selection ---
    if [ "$site_protocol" = "https" ]; then
        # Handle acme.sh certificate installation to Nginx preferred location
        if [[ "$opt" == *"acme.sh"* ]]; then
            local CERT_DIR="/etc/nginx/certs/$domain"
            mkdir -p "$CERT_DIR" || error "创建证书目录失败！/ Failed to create certificate directory!"
            
            # Ensure acme.sh environment is sourced again before installing cert
            if [ -f "$ACME_HOME_DIR/acme.sh.env" ]; then
                source "$ACME_HOME_DIR/acme.sh.env"
            else
                error "acme.sh 环境脚本未找到：$ACME_HOME_DIR/acme.sh.env / acme.sh environment script not found: $ACME_HOME_DIR/acme.sh.env"
            fi

            local install_cmd=("$ACME_CMD" --install-cert -d "$domain")
            if [ "$is_ecc" = true ]; then
                install_cmd+=("--ecc")
            fi
            install_cmd+=(--key-file "$CERT_DIR/privkey.pem" --fullchain-file "$CERT_DIR/fullchain.pem" --reloadcmd "systemctl reload nginx")
            info "正在执行: ${install_cmd[*]}"
            "${install_cmd[@]}" || error "安装 acme.sh 证书到 Nginx 目录失败！/ Failed to install acme.sh certificate to Nginx directory!"
            
            cert_path="$CERT_DIR/fullchain.pem"
            key_path="$CERT_DIR/privkey.pem"
        fi

        info "正在创建 HTTPS Nginx 配置... / Creating HTTPS Nginx configuration..."
        # Conditional fastcgi_pass include based on OS
        local FASTCGI_PHP_CONFIG=""
        if [ -n "$NGINX_FASTCGI_INCLUDE" ]; then
            FASTCGI_PHP_CONFIG="${NGINX_FASTCGI_INCLUDE}"
        else # For RHEL/CentOS, embed the fastcgi configuration directly
            FASTCGI_PHP_CONFIG="""
            fastcgi_split_path_info ^(.+\.php)(/.+)\$;
            fastcgi_pass unix:$PHP_FPM_SOCK_PATH;
            fastcgi_index index.php;
            include fastcgi_params; # Make sure this file exists, typically /etc/nginx/fastcgi_params
            """
        fi

        cat > "$NGINX_CONF_PATH" <<-EOF
server {
    listen 80; listen [::]:80;
    server_name $domain;
    return 301 https://\$host\$request_uri;
}
server {
    listen 443 ssl http2; listen [::]:443 ssl http2;
    server_name $domain;
    root $WP_PATH;
    index index.php;
    client_max_body_size 128M;

    ssl_certificate $cert_path;
    ssl_certificate_key $key_path;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers off; # Modern practice, Let's Encrypt provides strong ciphers

    # Add recommended SSL security headers
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains; preload" always;
    add_header X-Frame-Options "SAMEORIGIN";
    add_header X-Content-Type-Options "nosniff";
    add_header X-XSS-Protection "1; mode=block";
    add_header Referrer-Policy "no-referrer-when-downgrade";

    location / {
        try_files \$uri \$uri/ /index.php?\$args;
    }

    location ~ \.php\$ {
        # Dynamically include or embed fastcgi config
        ${FASTCGI_PHP_CONFIG}
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
    }

    # Deny access to hidden files and directories
    location ~ /\. {
        deny all;
    }

    # Cache static assets
    location ~* \.(jpg|jpeg|png|gif|ico|css|js|svg|woff|woff2|ttf|eot)$ {
        expires 7d;
        add_header Cache-Control "public, no-transform";
    }
}
EOF
    else # HTTP Only configuration
        info "正在创建仅 HTTP 的 Nginx 配置... / Creating HTTP-only Nginx configuration..."
        local FASTCGI_PHP_CONFIG=""
        if [ -n "$NGINX_FASTCGI_INCLUDE" ]; then
            FASTCGI_PHP_CONFIG="${NGINX_FASTCGI_INCLUDE}"
        else # For RHEL/CentOS, embed the fastcgi configuration directly
            FASTCGI_PHP_CONFIG="""
            fastcgi_split_path_info ^(.+\.php)(/.+)\$;
            fastcgi_pass unix:$PHP_FPM_SOCK_PATH;
            fastcgi_index index.php;
            include fastcgi_params;
            """
        fi

        cat > "$NGINX_CONF_PATH" <<-EOF
server {
    listen 80; listen [::]:80;
    server_name $domain;
    root $WP_PATH;
    index index.php;
    client_max_body_size 128M;

    location / {
        try_files \$uri \$uri/ /index.php?\$args;
    }

    location ~ \.php\$ {
        # Dynamically include or embed fastcgi config
        ${FASTCGI_PHP_CONFIG}
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
    }
    
    # Deny access to hidden files and directories
    location ~ /\. {
        deny all;
    }
}
EOF
    fi

    nginx -t || error "Nginx 配置文件测试失败！请检查 $NGINX_CONF_PATH / Nginx config test failed! Please check $NGINX_CONF_PATH"
    systemctl reload nginx || error "重载 Nginx 服务失败！/ Failed to reload Nginx service!"
    info "Nginx 配置完成。/ Nginx configuration complete."

    # Configure firewall
    info "正在配置防火墙规则... / Configuring firewall rules..."
    if command -v ufw &> /dev/null && ufw status | grep -q "Status: active"; then
        info "检测到防火墙 (ufw) 已激活。正在配置规则... / Firewall (ufw) is active. Configuring rules..."
        ufw allow 'Nginx Full' > /dev/null || warn "UFW 规则添加失败。请手动检查防火墙设置。/ UFW rule addition failed. Please manually check firewall settings."
    elif command -v firewall-cmd &> /dev/null && firewall-cmd --state | grep -q "running"; then
        info "检测到防火墙 (firewalld) 已激活。正在配置规则... / Firewall (firewalld) is active. Configuring rules..."
        firewall-cmd --permanent --add-service=http || warn "FirewallD HTTP 规则添加失败。/ FirewallD HTTP rule addition failed."
        if [ "$site_protocol" = "https" ]; then
            firewall-cmd --permanent --add-service=https || warn "FirewallD HTTPS 规则添加失败。/ FirewallD HTTPS rule addition failed."
        fi
        firewall-cmd --reload || warn "FirewallD 重载失败。/ FirewallD reload failed."
    else
        warn "未检测到 UFW 或 FirewallD 正在运行。请手动确保 80/443 端口已开放。/ Neither UFW nor FirewallD detected. Please manually ensure ports 80/443 are open."
    fi

    if [ "$site_protocol" = "https" ]; then
        info "正在将 WordPress 站点 URL 更新为 HTTPS... / Updating WordPress site URL to HTTPS..."
        sudo -u "$WEB_USER" wp option update home "https://$domain" --path="$WP_PATH" --quiet || warn "更新 WordPress HOME URL 为 HTTPS 失败。/ Failed to update WordPress HOME URL to HTTPS."
        sudo -u "$WEB_USER" wp option update siteurl "https://$domain" --path="$WP_PATH" --quiet || warn "更新 WordPress SITEURL 为 HTTPS 失败。/ Failed to update WordPress SITEURL to HTTPS."
    fi

    # --- 6. 保存配置以供卸载程序使用 / Save Configuration for Uninstaller ---
    mkdir -p "$(dirname "$CONFIG_FILE")" || error "创建配置目录失败！/ Failed to create config directory!"
    echo "DOMAIN=$domain" > "$CONFIG_FILE"
    echo "WP_PATH=$WP_PATH" >> "$CONFIG_FILE"
    echo "NGINX_CONF=$NGINX_CONF_PATH" >> "$CONFIG_FILE"
    echo "DB_NAME=$db_name" >> "$CONFIG_FILE"
    echo "DB_USER=$db_user" >> "$CONFIG_FILE"
    # Save acme.sh info if used, for precise removal later
    if [[ "$opt" == *"acme.sh"* ]]; then 
        echo "ACME_ECC=$is_ecc" >> "$CONFIG_FILE"
        echo "ACME_HOME_DIR=$ACME_HOME_DIR" >> "$CONFIG_FILE"
        echo "ACME_USED=true" >> "$CONFIG_FILE"
    fi

    # --- 7. 最终信息汇总 / Final Summary ---
    info "安装全部完成！/ Installation is fully complete!"
    echo
    echo -e "${GREEN}==================== 安装信息汇总 / Installation Summary ====================${NC}"
    printf "| %-25s | ${YELLOW}%-45s${NC} |\n" "网站地址 (Site URL)" "${site_protocol}://$domain"
    printf "| %-25s | %-45s |\n" "WordPress 管理员 (Admin)" "$admin_user"
    printf "| %-25s | ${RED}%-45s${NC} |\n" "WordPress 密码 (Password)" "$admin_pass"
    printf "|---------------------------|-----------------------------------------------|\n"
    printf "| %-25s | %-45s |\n" "数据库名称 (DB Name)" "$db_name"
    printf "| %-25s | %-45s |\n" "数据库用户 (DB User)" "$db_user"
    printf "| %-25s | ${RED}%-45s${NC} |\n" "数据库密码 (DB Password)" "$db_pass"
    printf "|---------------------------|-----------------------------------------------|\n"
    printf "| %-25s | %-45s |\n" "网站根目录 (Web Root)" "$WP_PATH"
    printf "| %-25s | %-45s |\n" "Nginx 配置 (Nginx Conf)" "$NGINX_CONF_PATH"
    printf "|---------------------------|-----------------------------------------------|\n"
    printf "| %-25s | ${YELLOW}%-45s${NC} |\n" "安全提醒 (Security Tip)" "sudo mysql_secure_installation"
    echo -e "============================================================================"
    echo
}


# ==============================================================================
# 卸载逻辑 / UNINSTALLATION LOGIC
# ==============================================================================
uninstall_wordpress() {
    warn "您将进入 WordPress 卸载程序。/ You are entering the WordPress uninstaller."

    local DOMAIN="" WP_PATH="" NGINX_CONF="" DB_NAME="" DB_USER="" ACME_ECC="" ACME_HOME_DIR="" ACME_USED=false # Initialize ACME_USED

    # Try to load configuration from file
    if [ -f "$CONFIG_FILE" ]; then 
        info "正在加载安装配置文件... / Loading installation config file..."
        source "$CONFIG_FILE" || warn "加载配置文件失败，将尝试自动发现。/ Failed to load config file, will attempt auto-discovery."
        # Convert ACME_ECC to boolean for safety in conditional checks
        if [[ "$ACME_ECC" == "true" ]]; then ACME_ECC=true; else ACME_ECC=false; fi
        if [[ "$ACME_USED" == "true" ]]; then ACME_USED=true; else ACME_USED=false; fi
    fi

    # If WP_PATH is still empty after loading config, try to auto-discover
    if [ -z "$WP_PATH" ]; then
        warn "未找到安装配置文件或配置不完整。将进入自动发现模式。"
        mapfile -t wp_configs < <(find /var /home -type f -name "wp-config.php" 2>/dev/null | grep -v -e '^/snap/' -e '^/var/lib/docker/')

        if [ ${#wp_configs[@]} -eq 0 ]; then
            warn "在服务器上没有找到任何 wp-config.php 文件。"
            read -p "是否要继续手动输入信息进行卸载？(y/N): " manual_uninstall_choice
            if [[ "$manual_uninstall_choice" == "y" || "$manual_uninstall_choice" == "Y" ]]; then
                read -p "请输入您要卸载的网站根目录路径 (例如 /var/www/example.com): " WP_PATH
                read -p "请输入数据库名称: " DB_NAME
                read -p "请输入数据库用户名: " DB_USER
                read -p "请输入 Nginx 配置文件路径 (例如 /etc/nginx/conf.d/example.com.conf): " NGINX_CONF
                if [ -n "$NGINX_CONF" ]; then
                    DOMAIN=$(basename "$NGINX_CONF" .conf)
                fi
            else
                error "未发现 WordPress 实例且用户选择不手动输入，卸载中止。/ No WordPress instances found and user chose not to manually input. Uninstallation aborted."
            fi
        else
            info "发现以下 WordPress 实例，请选择要卸载的一个："
            select selected_config in "${wp_configs[@]}" "以上都不是/跳过 (None of above/Skip)"; do
                if [ -n "$selected_config" ] && [ "$selected_config" != "以上都不是/跳过 (None of above/Skip)" ]; then
                    WP_PATH=$(dirname "$selected_config")
                    DB_NAME=$(grep "DB_NAME" "$selected_config" | cut -d \' -f 4) || warn "无法从 wp-config.php 获取数据库名称。/ Could not get DB name from wp-config.php."
                    DB_USER=$(grep "DB_USER" "$selected_config" | cut -d \' -f 4) || warn "无法从 wp-config.php 获取数据库用户。/ Could not get DB user from wp-config.php."
                    NGINX_CONF=$(grep -lr "root.*$WP_PATH" /etc/nginx/conf.d/ /etc/nginx/sites-enabled/ 2>/dev/null | head -n 1)
                    if [ -n "$NGINX_CONF" ]; then
                        DOMAIN=$(basename "$NGINX_CONF" .conf)
                    else
                        DOMAIN=$(basename "$WP_PATH") # Fallback to path name for domain
                    fi
                    break
                elif [ "$selected_config" == "以上都不是/跳过 (None of above/Skip)" ]; then
                    info "已跳过基于 wp-config.php 的卸载。/ Skipped wp-config.php based uninstallation."
                    WP_PATH="" # Reset WP_PATH to trigger manual input or exit if needed
                    break
                fi
            done
        fi
    fi

    if [ -n "$WP_PATH" ]; then
        info "将卸载与路径 '$WP_PATH' 相关的组件..."
        warn "此操作将永久删除网站文件、数据库和相关配置。数据无法恢复！"
        read -p "请输入网站路径 '$WP_PATH' 以确认删除： " confirm_path
        if [ "$confirm_path" != "$WP_PATH" ]; then error "路径输入不匹配，卸载已中止。/ Path input mismatch, uninstallation aborted."; fi

        info "开始执行删除流程... / Starting deletion process..."

        # --- MariaDB 数据库和用户删除 (在停止服务前执行) ---
        info "-> 正在确保 MariaDB 服务运行以执行数据库操作... / Ensuring MariaDB service is running for database operations..."
        # 仅当 MariaDB 服务未激活时才尝试启动，并设置为非致命
        systemctl is-active mariadb &> /dev/null || systemctl start mariadb || warn "无法启动 MariaDB 服务，数据库操作可能失败。/ Failed to start MariaDB service, database operations may fail."
        
        # 只有当 MariaDB 活跃时才尝试删除数据库和用户
        if systemctl is-active mariadb &> /dev/null; then
            if [ -n "$DB_NAME" ]; then
                info "-> 正在删除数据库 $DB_NAME... / Deleting database $DB_NAME..."
                mysql -u root -e "DROP DATABASE IF EXISTS \`$DB_NAME\`;" || warn "删除数据库失败。/ Failed to delete database."
            fi

            if [ -n "$DB_USER" ]; then
                info "-> 正在删除数据库用户 $DB_USER... / Deleting database user $DB_USER..."
                mysql -u root -e "DROP USER IF EXISTS '$DB_USER'@'localhost';" || warn "删除数据库用户失败。/ Failed to delete database user."
            fi
        else
            warn "MariaDB 服务未运行，跳过数据库和用户删除。/ MariaDB service is not running, skipping database and user deletion."
        fi

        # --- 停止核心服务 (在数据库操作之后，文件删除之前) ---
        info "-> 正在停止 Nginx, PHP-FPM, MariaDB 服务... / Stopping Nginx, PHP-FPM, MariaDB services..."
        systemctl stop nginx || warn "停止 Nginx 服务失败，可能未运行。/ Failed to stop Nginx, might not be running."
        systemctl stop mariadb || warn "停止 MariaDB 服务失败，可能未运行。/ Failed to stop MariaDB, might not be running."
        
        # 动态确定 PHP-FPM 服务名 (在卸载时)
        local current_php_version=""
        if command -v php &> /dev/null; then
            current_php_version=$(php -r "echo PHP_MAJOR_VERSION . '.' . PHP_MINOR_VERSION;" 2>/dev/null)
        fi

        local actual_php_fpm_service="$PHP_FPM_SERVICE" # 使用 detect_os_and_set_vars 设定的默认值
        if [[ "$OS_ID" == "ubuntu" || "$OS_ID" == "debian" ]] && [ -n "$current_php_version" ]; then
            actual_php_fpm_service="php${current_php_version}-fpm"
        fi
        
        systemctl stop "$actual_php_fpm_service" || warn "停止 $actual_php_fpm_service 服务失败，可能未运行或服务名不匹配。/ Failed to stop $actual_php_fpm_service, might not be running or service name mismatch."

        # --- 文件和配置删除 ---
        if [ -n "$NGINX_CONF" ] && [ -f "$NGINX_CONF" ]; then
            info "-> 正在移除 Nginx 配置文件 $NGINX_CONF... / Removing Nginx configuration file $NGINX_CONF..."
            rm -f "$NGINX_CONF" || warn "移除 Nginx 配置文件失败。/ Failed to remove Nginx config file."
        fi

        # Determine ACME_CMD and ACME_HOME_DIR for certificate removal
        local ACME_CMD_UNINSTALL=""
        local ACME_HOME_DIR_UNINSTALL=""

        # Prefer loaded values from config file first
        if [ "$ACME_USED" = true ]; then
            ACME_HOME_DIR_UNINSTALL="$ACME_HOME_DIR"
            if [ -f "$ACME_HOME_DIR_UNINSTALL/acme.sh" ]; then
                ACME_CMD_UNINSTALL="$ACME_HOME_DIR_UNINSTALL/acme.sh"
            fi
        else # Try to discover if not used based on config, or if config was missing
            local potential_acme_homes_uninstall=("/root/.acme.sh" "/etc/acme.sh" "/var/lib/acme.sh")
            for home in "${potential_acme_homes_uninstall[@]}"; do
                if [ -f "$home/acme.sh" ]; then
                    ACME_HOME_DIR_UNINSTALL=$home
                    ACME_CMD_UNINSTALL="$home/acme.sh"
                    break
                fi
            done
        fi
        
        if [ -n "$DOMAIN" ] && [ -n "$ACME_CMD_UNINSTALL" ] && [ -n "$ACME_HOME_DIR_UNINSTALL" ]; then
            # Ensure acme.sh environment is sourced before attempting removal
            if [ -f "$ACME_HOME_DIR_UNINSTALL/acme.sh.env" ]; then
                source "$ACME_HOME_DIR_UNINSTALL/acme.sh.env" || warn "无法加载 acme.sh 环境。/ Could not load acme.sh environment."
            fi
            
            local remove_cmd=("$ACME_CMD_UNINSTALL" --remove -d "$DOMAIN")
            if [ "$ACME_ECC" = true ]; then remove_cmd+=("--ecc"); fi # Only add --ecc if it was an ECC cert
            info "-> 正在移除 acme.sh 证书: ${remove_cmd[*]}... / Removing acme.sh certificate: ${remove_cmd[*]}..."
            "${remove_cmd[@]}" || warn "移除 acme.sh 证书失败。/ Failed to remove acme.sh certificate."
        fi

        if [ -n "$DOMAIN" ] && [ -d "/etc/nginx/certs/$DOMAIN" ]; then
            info "-> 正在移除安装的证书目录 /etc/nginx/certs/$DOMAIN... / Removing installed certificate directory /etc/nginx/certs/$DOMAIN..."
            rm -rf "/etc/nginx/certs/$DOMAIN" || warn "移除证书目录失败。/ Failed to remove certificate directory."
        fi

        if [ -d "$WP_PATH" ]; then
            info "-> 正在删除 WordPress 目录 $WP_PATH... / Deleting WordPress directory $WP_PATH..."
            rm -rf "$WP_PATH" || warn "删除 WordPress 目录失败。/ Failed to delete WordPress directory."
        fi
        
        info "-> 正在重载 Nginx 并清理配置文件... / Reloading Nginx and cleaning up config..."
        # 仅当 Nginx 服务活跃时才尝试重载
        if systemctl is-active nginx &> /dev/null; then
            nginx -t && systemctl reload nginx || warn "Nginx 配置测试或重载失败，请手动检查。/ Nginx config test or reload failed, please check manually."
        else
            nginx -t &> /dev/null && info "Nginx 配置测试通过，但服务未运行，无需重载。/ Nginx config test passed, but service not running, no reload needed." || warn "Nginx 配置测试失败，但服务未运行，请手动检查。/ Nginx config test failed, but service not running, please check manually."
        fi

        # Remove the installer's config file
        if [ -f "$CONFIG_FILE" ]; then
            info "-> 正在移除安装程序配置文件目录 $(dirname "$CONFIG_FILE")... / Removing installer config file directory $(dirname "$CONFIG_FILE")..."
            rm -rf "$(dirname "$CONFIG_FILE")" || warn "移除安装程序配置文件失败。/ Failed to remove installer config file."
        fi

        info "相关组件卸载完成。/ Related components have been uninstalled."
    else
        warn "未检测到要卸载的 WordPress 实例。/ No WordPress instance detected for uninstallation."
    fi

    warn "现在，您可以选择是否彻底清除本脚本安装的核心软件包。"
    read -p "您想完全卸载 Nginx, MariaDB, PHP 等软件包吗？(y/N): " purge_packages
    if [[ "$purge_packages" == "y" || "$purge_packages" == "Y" ]]; then
        info "正在清除软件包... / Purging packages..."
        # Refined package purge list to prevent over-purging.
        # It's better to explicitly list packages that were installed by this script.
        local packages_to_purge="nginx mariadb-server php-fpm php-mysql php-curl php-gd php-mbstring php-xml php-xmlrpc php-soap php-intl php-zip php-imagick php-bcmath"
        if [[ "$OS_ID" == "centos" || "$OS_ID" == "rhel" || "$OS_ID" == "fedora" || "$OS_ID" == "rocky" || "$OS_ID" == "almalinux" ]]; then
            packages_to_purge="nginx mariadb-server php-fpm php-mysqlnd php-curl php-gd php-mbstring php-xml php-xmlrpc php-soap php-intl php-zip php-pecl-imagick php-bcmath"
        fi
        
        # Add the specific PHP FPM service name for Debian/Ubuntu
        if [[ "$OS_ID" == "ubuntu" || "$OS_ID" == "debian" ]]; then
            # 替换通用 php-fpm 为实际版本化的服务名称，如果检测到
            local current_php_cli_version=$(php -r "echo PHP_MAJOR_VERSION . '.' . PHP_MINOR_VERSION;" 2>/dev/null)
            if [ -n "$current_php_cli_version" ]; then
                packages_to_purge=$(echo "$packages_to_purge" | sed "s/php-fpm/php${current_php_cli_version}-fpm php${current_php_cli_version}-cli/")
            else
                packages_to_purge=$(echo "$packages_to_purge" | sed "s/php-fpm/php-fpm php-cli/") # Fallback to generic if version not found
            fi
        fi

        $PKG_CMD_PURGE $packages_to_purge || warn "软件包清除失败。请手动检查并清理。/ Package purging failed. Please check and clean manually."
        info "软件包已清除。/ Packages purged."
    fi

    info "--------------------------------------------------------"
    info "卸载完成。/ Uninstallation complete."
    info "--------------------------------------------------------"
}


# ==============================================================================
# 脚本入口点 / SCRIPT ENTRY POINT
# ==============================================================================
main() {
    ensure_bash
    check_root
    # detect_os_and_set_vars 必须在 main 函数中，因为它设置了全局变量
    detect_os_and_set_vars 

    case "$1" in
        install)
            install_wordpress
            ;;
        uninstall)
            uninstall_wordpress
            ;;
        *)
            echo "用法 (Usage): sudo bash $0 {install|uninstall}"
            exit 1
            ;;
    esac
}

main "$@"
