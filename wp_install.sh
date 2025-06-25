#!/bin/bash

# ==============================================================================
# 全自动 WordPress LEMP + 灵活 SSL 安装脚本 (Ubuntu/Debian 专用版)
# Fully Automated WordPress on LEMP + Flexible SSL Installer (Ubuntu/Debian Only)
#
# Author: logover
# Version: 1.1
# Description: 自动检测操作系统 (仅支持 Debian/Ubuntu) 并安装
#              WordPress LEMP 环境。使用 WP-CLI 跳过网页安装，提供灵活的 SSL
#              选项和中文安装选项。
# ==============================================================================

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
PHP_FPM_SERVICE="" # Will be phpX.Y-fpm
PHP_FPM_SOCK_PATH="/run/php/php-fpm.sock" # Fixed socket path as requested

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
detect_os_and_set_vars() {
    info "正在检测操作系统... / Detecting operating system..."
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS_ID=$ID
    else
        error "无法检测操作系统，/etc/os-release 文件不存在。/ Cannot detect OS, /etc/os-release not found."
    fi

    info "检测到操作系统为: $OS_ID / Detected OS: $OS_ID"

    case "$OS_ID" in
        ubuntu|debian)
            PKG_CMD_UPDATE="apt-get update -y"
            PKG_CMD_INSTALL="apt-get install -y"
            PKG_CMD_PURGE="apt-get purge --auto-remove -y"
            # socat for acme.sh --issue -d "$domain" --standalone, though webroot is used here. Keeping for completeness.
            REQUIRED_PACKAGES="nginx mariadb-server php-fpm php-mysql php-curl php-gd php-mbstring php-xml php-xmlrpc php-soap php-intl php-zip php-imagick php-bcmath wget curl socat"
            WEB_USER="www-data"
            # Forcing PHP_VERSION detection here as it's critical for service name
            PHP_VERSION=$(php -r "echo PHP_MAJOR_VERSION . '.' . PHP_MINOR_VERSION;" 2>/dev/null)
            if [ -z "$PHP_VERSION" ]; then
                warn "无法在当前环境检测到 PHP 版本，将尝试安装默认 PHP-FPM 并后续获取版本号。"
                # Assign a common default for initial install, will re-evaluate after php-ffpm is installed
                PHP_FPM_SERVICE="php-fpm" # Temporarily, will get actual version after install
            else
                PHP_FPM_SERVICE="php$PHP_VERSION-fpm"
            fi
            # PHP_FPM_SOCK_PATH already fixed to /run/php/php-fpm.sock
            ;;
        *)
            error "不支持的操作系统: $OS_ID. 此脚本仅支持 Debian/Ubuntu。/ Unsupported operating system: $OS_ID. This script only supports Debian/Ubuntu."
            ;;
    esac
}


# ==============================================================================
# 安装逻辑 / INSTALLATION LOGIC (V7.0)
# ==============================================================================
install_wordpress() {
    info "开始全自动 WordPress + 灵活 SSL 安装... / Starting Fully Automated WordPress + Flexible SSL installation..."

    # --- 1. 收集所有必要信息 / Gather All Necessary Information ---
    read -p "请输入您的域名 (例如 example.com) / Please enter your domain name (e.g., example.com): " domain
    if [ -z "$domain" ]; then error "域名不能为空。/ Domain name cannot be empty."; fi
    ssl_email="bot-$(openssl rand -hex 4)@$domain"
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
        [ "$admin_pass" = "$admin_pass_confirm" ] && ! [ -z "$admin_pass" ] && break
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
        [ "$db_pass" = "$db_pass_confirm" ] && ! [ -z "$db_pass" ] && break
        warn "密码不匹配或为空，请重试。/ Passwords do not match or are empty. Please try again."
    done

    WP_PATH="/var/www/$domain"

    # --- 2. 更新系统并安装软件包 / Update System and Install Packages ---
    info "正在更新软件包列表... / Updating package lists..."
    $PKG_CMD_UPDATE
    info "正在安装所需软件包... / Installing required packages..."
    $PKG_CMD_INSTALL $REQUIRED_PACKAGES
    if [ $? -ne 0 ]; then
        error "软件包安装失败！请检查包管理器的输出信息以确定问题。/ Package installation failed! Please check the package manager output for details."
    fi

    # After initial install, determine the actual PHP version and update PHP_FPM_SERVICE
    PHP_VERSION=$(php -r "echo PHP_MAJOR_VERSION . '.' . PHP_MINOR_VERSION;" 2>/dev/null)
    if [ -z "$PHP_VERSION" ]; then
        error "安装 PHP 软件包后无法检测到 PHP 版本。/ Failed to detect PHP version after package installation."
    else
        PHP_FPM_SERVICE="php$PHP_VERSION-fpm"
        info "检测到 PHP-FPM 服务名称为: $PHP_FPM_SERVICE"
    fi

    info "软件包安装成功。/ Packages installed successfully."

    # --- 2b. 安装 WP-CLI / Install WP-CLI ---
    if ! command -v wp &> /dev/null; then
        info "正在安装 WP-CLI... / Installing WP-CLI..."
        curl -sO https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar
        chmod +x wp-cli.phar
        mv wp-cli.phar /usr/local/bin/wp
    fi

    # --- 3. 配置 LEMP 核心服务 / Configure Core LEMP Services ---
    info "正在启动并启用 MariaDB 和 PHP-FPM 服务... / Starting and enabling MariaDB & PHP-FPM services..."
    systemctl start mariadb && systemctl enable mariadb
    systemctl start "$PHP_FPM_SERVICE" && systemctl enable "$PHP_FPM_SERVICE"

    info "正在配置 PHP 上传及内存限制... / Configuring PHP upload & memory limits..."
    # Find php.ini path more robustly
    PHP_INI_PATH=$(php -i | grep "Loaded Configuration File" | sed 's/Loaded Configuration File => //')
    if [ -z "$PHP_INI_PATH" ]; then
        warn "无法自动定位 php.ini 文件，跳过 PHP 限制配置。 / Could not auto-locate php.ini, skipping PHP limit configuration."
    else
        info "找到 php.ini 文件: $PHP_INI_PATH"
        sed -i "s/^\s*;*\s*upload_max_filesize\s*=\s*.*/upload_max_filesize = 128M/" "$PHP_INI_PATH"
        sed -i "s/^\s*;*\s*post_max_size\s*=\s*.*/post_max_size = 128M/" "$PHP_INI_PATH"
        sed -i "s/^\s*;*\s*memory_limit\s*=\s*.*/memory_limit = 256M/" "$PHP_INI_PATH"
        systemctl restart "$PHP_FPM_SERVICE" # Correct service name with version
    fi

    info "正在配置 MariaDB 数据库和用户... / Configuring MariaDB database and user..."
    DB_EXISTS=$(mysql -u root -e "SHOW DATABASES LIKE '$db_name';" | grep "$db_name" > /dev/null; echo "$?")
    if [ "$DB_EXISTS" -eq 0 ]; then
        warn "数据库 '$db_name' 已存在。/ Database '$db_name' already exists."
        read -p "您想删除它并创建一个全新的吗？(y/N) / Do you want to delete it and create a new one? (y/N): " delete_db
        if [[ "$delete_db" == "y" || "$delete_db" == "Y" ]]; then
            info "正在删除现有数据库... / Deleting existing database..."
            mysql -u root -e "DROP DATABASE \`$db_name\`;"
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
    if [ $? -ne 0 ]; then error "数据库配置失败！请检查 MariaDB 服务状态和 root 密码。/ Database configuration failed!"; fi

    # --- 4. 配置 WordPress (文件和数据库) / Configure WordPress (Files & Database) ---
    info "正在创建并准备 WordPress 目录 $WP_PATH... / Creating and preparing WordPress directory $WP_PATH..."
    mkdir -p "$WP_PATH"

    if [ "$(ls -A "$WP_PATH")" ]; then
        warn "目录 $WP_PATH 不是空的。/ Directory $WP_PATH is not empty."
        read -p "您想清空它并继续安装吗？(这会删除里面的所有文件！) (y/N) / Do you want to empty it and continue? (This will delete all files inside!) (y/N): " clear_dir
        if [[ "$clear_dir" == "y" || "$clear_dir" == "Y" ]]; then
            info "正在清空目录... / Emptying directory..."
            rm -rf "$WP_PATH"/*
        else
            error "用户选择不清空目录，安装中止。/ User chose not to empty the directory. Installation aborted."
        fi
    fi

    info "正在下载 WordPress... / Downloading WordPress..."
    cd /tmp
    wget -q https://wordpress.org/latest.tar.gz -O wordpress.tar.gz
    if [ $? -ne 0 ]; then error "下载 WordPress 压缩包失败！/ Failed to download WordPress archive!"; fi

    info "正在解压 WordPress... / Extracting WordPress..."
    tar -xzf wordpress.tar.gz -C "$WP_PATH" --strip-components=1
    if [ $? -ne 0 ]; then error "解压 WordPress 失败！/ Failed to extract WordPress!"; fi
    rm wordpress.tar.gz

    # Use OS-specific web user
    chown -R "$WEB_USER:$WEB_USER" "$WP_PATH"
    find "$WP_PATH" -type d -exec chmod 755 {} \;
    find "$WP_PATH" -type f -exec chmod 644 {} \;

    info "正在通过 WP-CLI 完成核心安装... / Running core install with WP-CLI..."
    # Use OS-specific web user
    sudo -u "$WEB_USER" wp config create --path="$WP_PATH" --dbname="$db_name" --dbuser="$db_user" --dbpass="$db_pass" --dbcharset="utf8mb4" --quiet
    if [ $? -ne 0 ]; then error "使用 WP-CLI 创建 wp-config.php 失败！请检查数据库连接信息。/ Failed to create wp-config.php!"; fi

    info "正在安装 WordPress 核心 (英文版)..."
    sudo -u "$WEB_USER" wp core install --path="$WP_PATH" --url="http://$domain" --title="$site_title" --admin_user="$admin_user" --admin_password="$admin_pass" --admin_email="$admin_email" --skip-email
    if [ $? -ne 0 ]; then error "使用 WP-CLI 安装 WordPress 核心失败！/ Failed to install WordPress core using WP-CLI!"; fi

    read -p "是否需要为 WordPress 安装并激活简体中文? (y/N) / Install and activate Chinese (Simplified) for WordPress? (y/N): " install_chinese
    if [[ "$install_chinese" == "y" || "$install_chinese" == "Y" ]]; then
        info "正在准备语言目录... / Preparing languages directory..."
        sudo -u "$WEB_USER" mkdir -p "$WP_PATH/wp-content/languages"
        info "正在下载并安装简体中文语言包... / Downloading and installing Chinese (Simplified) language pack..."
        sudo -u "$WEB_USER" wp language core install zh_CN --path="$WP_PATH"
        if [ $? -ne 0 ]; then
            warn "下载中文语言包失败。/ Failed to download Chinese language pack."
        else
            info "正在激活简体中文... / Activating Chinese (Simplified)..."
            sudo -u "$WEB_USER" wp site switch-language zh_CN --path="$WP_PATH"
            info "简体中文已激活。/ Chinese (Simplified) has been activated."
        fi
    else
        info "已跳过中文安装。/ Skipped Chinese language installation."
    fi

    info "正在根据系统设置 WordPress 时区... / Setting WordPress timezone from system..."
    SYSTEM_TIMEZONE=$(timedatectl show --property=Timezone --value)
    if [ -n "$SYSTEM_TIMEZONE" ]; then
        sudo -u "$WEB_USER" wp option update timezone_string "$SYSTEM_TIMEZONE" --path="$WP_PATH"
    fi
    info "WordPress 核心安装已通过命令行完成！/ WordPress core installation via CLI is complete!"

    # --- 5. SSL证书配置 / SSL Certificate Configuration ---
    NGINX_CONF_PATH="/etc/nginx/conf.d/${domain}.conf"
    if [ -f /etc/nginx/sites-enabled/default ]; then rm /etc/nginx/sites-enabled/default; fi # Debian/Ubuntu specific, but safe elsewhere
    site_protocol="http"

    info "正在检测已有的 SSL 证书... / Detecting existing SSL certificates..."
    ACME_CMD=""
    ACME_HOME_DIR=""
    found_acme_cert_type=""
    potential_acme_execs=("acme.sh" "acme")
    for cmd in "${potential_acme_execs[@]}"; do
        if command -v "$cmd" &> /dev/null; then
            ACME_CMD=$(command -v "$cmd")
            info "检测到 acme 工具: $ACME_CMD"
            break
        fi
    done
    potential_acme_homes=("/root/.acme.sh" "/etc/acme.sh" "/var/lib/acme" "$HOME/.acme.sh")
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
        potential_dirs=($(find "$ACME_HOME_DIR" -maxdepth 1 -type d -name "$domain*"))
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
    found_certbot_cert=false
    if command -v certbot &> /dev/null; then
        certbot_live_dir="/etc/letsencrypt/live/$domain"
        if [ -d "$certbot_live_dir" ]; then
            if [ -f "$certbot_live_dir/privkey.pem" ] && [ -f "$certbot_live_dir/fullchain.pem" ]; then
                found_certbot_cert=true
            fi
        fi
    fi
    options=()
    if [ "$found_acme_cert_type" == "ECC" ]; then options+=("使用已检测到的 acme.sh ECC 证书"); fi
    if [ "$found_acme_cert_type" == "RSA" ]; then options+=("使用已检测到的 acme.sh RSA 证书"); fi
    if [ "$found_certbot_cert" = true ]; then options+=("使用已检测到的 certbot 证书 ($domain)"); fi
    options+=("使用 acme.sh 申请新证书 (ECC)")
    options+=("手动提供已有证书路径")
    options+=("跳过SSL，仅使用 HTTP")
    options+=("退出安装")
    info "请选择您的 SSL 配置方案 / Please select your SSL configuration option:"
    select opt in "${options[@]}"; do
        case $opt in
            "使用已检测到的 acme.sh ECC 证书") site_protocol="https"; is_ecc=true; break ;;
            "使用已检测到的 acme.sh RSA 证书") site_protocol="https"; is_ecc=false; break ;;
            "使用已检测到的 certbot 证书 ($domain)") site_protocol="https"; cert_path="/etc/letsencrypt/live/$domain/fullchain.pem"; key_path="/etc/letsencrypt/live/$domain/privkey.pem"; opt="手动提供已有证书路径"; ;;&
            "使用 acme.sh 申请新证书 (ECC)")
                site_protocol="https"
                is_ecc=true
                warn "自动申请证书需要确保您的域名 ($domain) 已正确解析到本服务器IP！"
                read -p "按回车键继续... / Press Enter to continue..."
                if [ -z "$ACME_CMD" ]; then
                    info "正在安装 acme.sh... / Installing acme.sh..."
                    curl -s https://get.acme.sh | sh -s email="$ssl_email"
                    ACME_HOME_DIR="/root/.acme.sh"
                    ACME_CMD="$ACME_HOME_DIR/acme.sh"
                fi
                source "$ACME_HOME_DIR/acme.sh.env"
                info "正在配置 Nginx (HTTP) 以进行域名验证..."
                cat > "$NGINX_CONF_PATH" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name $domain;
    root $WP_PATH;
    location ~ /.well-known/acme-challenge/ { allow all; }
    location / { return 404; }
}
EOF
                nginx -t && systemctl reload nginx
                info "正在使用 acme.sh 获取新的 ECC SSL 证书..."
                "$ACME_CMD" --issue -d "$domain" -w "$WP_PATH" --ecc
                if [ $? -ne 0 ]; then error "使用acme.sh签发证书失败！/ Failed to issue cert with acme.sh!"; fi
                break
                ;;
            "手动提供已有证书路径")
                site_protocol="https"
                if [ -z "$cert_path" ]; then
                    read -ep "请输入您的证书文件 (fullchain) 的完整路径: " cert_path
                    read -ep "请输入您的私钥文件 (privkey) 的完整路径: " key_path
                fi
                if [ ! -f "$cert_path" ] || [ ! -f "$key_path" ]; then
                    error "提供的证书或私钥文件路径无效！"
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
        if [[ "$opt" == *"acme.sh"* ]]; then
            CERT_DIR="/etc/nginx/certs/$domain"
            mkdir -p "$CERT_DIR"
            source "$ACME_HOME_DIR/acme.sh.env"
            install_cmd=("$ACME_CMD" --install-cert -d "$domain")
            if [ "$is_ecc" = true ]; then
                install_cmd+=("--ecc")
            fi
            install_cmd+=(--key-file "$CERT_DIR/privkey.pem" --fullchain-file "$CERT_DIR/fullchain.pem" --reloadcmd "systemctl reload nginx")
            info "正在执行: ${install_cmd[*]}"
            "${install_cmd[@]}"
            if [ $? -ne 0 ]; then error "安装 acme.sh 证书到 Nginx 目录失败！"; fi
            cert_path="$CERT_DIR/fullchain.pem"
            key_path="$CERT_DIR/privkey.pem"
        fi

        info "正在创建 HTTPS Nginx 配置..."
        # Use fixed PHP FPM socket path
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
		    ssl_prefer_server_ciphers off;

		    location / { try_files \$uri \$uri/ /index.php?\$args; }

		    location ~ \.php\$ {
		        include snippets/fastcgi-php.conf;
		        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
		        fastcgi_pass unix:$PHP_FPM_SOCK_PATH;
		    }
		    location ~* \.(jpg|jpeg|png|gif|ico|css|js|svg|woff|woff2|ttf|eot)$ {
		        expires 7d; add_header Cache-Control "public, no-transform";
		    }
		    location ~ /\.ht { deny all; }
		}
		EOF
    else # HTTP
        info "正在创建仅 HTTP 的 Nginx 配置..."
        cat > "$NGINX_CONF_PATH" <<-EOF
		server {
		    listen 80; listen [::]:80;
		    server_name $domain;
		    root $WP_PATH;
		    index index.php;
		    client_max_body_size 128M;

		    location / { try_files \$uri \$uri/ /index.php?\$args; }

		    location ~ \.php\$ {
		        include snippets/fastcgi-php.conf;
		        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
		        fastcgi_pass unix:$PHP_FPM_SOCK_PATH;
		    }
		}
		EOF
    fi

    if ! nginx -t; then
        error "Nginx 配置文件测试失败！请检查 $NGINX_CONF_PATH / Nginx config test failed! Please check $NGINX_CONF_PATH"
    fi
    systemctl reload nginx
    info "Nginx 配置完成。"

    if command -v ufw &> /dev/null && ufw status | grep -q "Status: active"; then
        info "检测到防火墙 (ufw) 已激活。正在配置规则... / Firewall (ufw) is active. Configuring rules..."
        ufw allow 'Nginx Full' > /dev/null
    elif command -v firewall-cmd &> /dev/null && firewall-cmd --state | grep -q "running"; then
        warn "当前系统不是 Ubuntu/Debian，Firewalld 相关配置将被跳过。" # Original script had this, keeping as a harmless warning now.
    fi

    if [ "$site_protocol" = "https" ]; then
        info "正在将 WordPress 站点 URL 更新为 HTTPS..."
        sudo -u "$WEB_USER" wp option update home "https://$domain" --path="$WP_PATH" --quiet
        sudo -u "$WEB_USER" wp option update siteurl "https://$domain" --path="$WP_PATH" --quiet
    fi

    # --- 6. 保存配置以供卸载程序使用 / Save Configuration for Uninstaller ---
    mkdir -p "$(dirname "$CONFIG_FILE")"
    echo "DOMAIN=$domain" > "$CONFIG_FILE"; echo "WP_PATH=$WP_PATH" >> "$CONFIG_FILE"; echo "NGINX_CONF=$NGINX_CONF_PATH" >> "$CONFIG_FILE"; echo "DB_NAME=$db_name" >> "$CONFIG_FILE"; echo "DB_USER=$db_user" >> "$CONFIG_FILE";
    echo "PHP_FPM_SERVICE=$PHP_FPM_SERVICE" >> "$CONFIG_FILE"; # Save PHP-FPM service name
    if [[ "$opt" == *"acme.sh"* ]]; then echo "ACME_ECC=$is_ecc" >> "$CONFIG_FILE"; echo "ACME_HOME_DIR=$ACME_HOME_DIR" >> "$CONFIG_FILE"; fi

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
# 卸载逻辑 / UNINSTALLATION LOGIC (V7.0)
# ==============================================================================
uninstall_wordpress() {
    warn "您将进入 WordPress 卸载程序。/ You are entering the WordPress uninstaller."

    local DOMAIN="" WP_PATH="" NGINX_CONF="" DB_NAME="" DB_USER="" ACME_ECC="" ACME_HOME_DIR="" PHP_FPM_SERVICE_UNINSTALL=""
    if [ -f "$CONFIG_FILE" ]; then source "$CONFIG_FILE"; fi

    # If PHP_FPM_SERVICE was saved, use it. Otherwise, try to infer default.
    if [ -z "$PHP_FPM_SERVICE" ]; then
        PHP_VERSION_UNINSTALL=$(php -r "echo PHP_MAJOR_VERSION . '.' . PHP_MINOR_VERSION;" 2>/dev/null)
        if [ -n "$PHP_VERSION_UNINSTALL" ]; then
            PHP_FPM_SERVICE_UNINSTALL="php$PHP_VERSION_UNINSTALL-fpm"
        else
            PHP_FPM_SERVICE_UNINSTALL="php-fpm" # Fallback for purge if no specific version found
        fi
    else
        PHP_FPM_SERVICE_UNINSTALL="$PHP_FPM_SERVICE"
    fi


    if [ -z "$WP_PATH" ]; then
        warn "未找到安装配置文件。将进入自动发现模式。"
        mapfile -t wp_configs < <(find /var/www /var/lib/wordpress /opt/wordpress /srv/wordpress /home -type f -name "wp-config.php" 2>/dev/null | grep -v -e '^/snap/' -e '^/var/lib/docker/')

        if [ ${#wp_configs[@]} -eq 0 ]; then
            warn "在服务器上没有找到任何 wp-config.php 文件。"
        else
            info "发现以下 WordPress 实例，请选择要卸载的一个："
            select selected_config in "${wp_configs[@]}" "以上都不是/跳过 (None of above/Skip)"; do
                if [ -n "$selected_config" ] && [ "$selected_config" != "以上都不是/跳过 (None of above/Skip)" ]; then
                    WP_PATH=$(dirname "$selected_config")
                    DB_NAME=$(grep "DB_NAME" "$selected_config" | cut -d \' -f 4)
                    DB_USER=$(grep "DB_USER" "$selected_config" | cut -d \' -f 4)
                    NGINX_CONF=$(grep -lr "root.*$WP_PATH" /etc/nginx/conf.d/ /etc/nginx/sites-enabled/ | head -n 1)
                    if [ -n "$NGINX_CONF" ]; then
                         DOMAIN=$(basename "$NGINX_CONF" .conf)
                    else
                         DOMAIN=$(basename "$WP_PATH")
                    fi
                    break
                elif [ "$selected_config" == "以上都不是/跳过 (None of above/Skip)" ]; then
                    info "已跳过基于 wp-config.php 的卸载。"
                    WP_PATH=""
                    break
                fi
            done
        fi
    fi

    if [ -n "$WP_PATH" ]; then
        info "将卸载与路径 '$WP_PATH' 相关的组件..."
        warn "此操作将永久删除网站文件、数据库和相关配置。数据无法恢复！"
        read -p "请输入网站路径 '$WP_PATH' 以确认删除： " confirm_path
        if [ "$confirm_path" != "$WP_PATH" ]; then error "路径输入不匹配，卸载已中止。"; fi

        info "开始执行删除流程... / Starting deletion process..."
        if [ -n "$NGINX_CONF" ] && [ -f "$NGINX_CONF" ]; then
            info "-> 正在移除 Nginx 配置文件 $NGINX_CONF..."
            rm -f "$NGINX_CONF"
        fi
        ACME_CMD=""
        if [ -z "$ACME_HOME_DIR" ]; then
            potential_acme_homes=("/root/.acme.sh" "/etc/acme.sh" "/var/lib/acme.sh")
            for home in "${potential_acme_homes[@]}"; do if [ -f "$home/acme.sh" ]; then ACME_HOME_DIR=$home; ACME_CMD="$home/acme.sh"; break; fi; done
        fi
        if [ -n "$DOMAIN" ] && [ -n "$ACME_CMD" ]; then
            remove_cmd=("$ACME_CMD" --remove -d "$DOMAIN")
            if [ "$ACME_ECC" = true ]; then remove_cmd+=("--ecc"); fi
            info "-> 正在移除 acme.sh 证书: ${remove_cmd[*]}"
            source "$ACME_HOME_DIR/acme.sh.env"; "${remove_cmd[@]}"
        fi
        if [ -n "$DOMAIN" ] && [ -d "/etc/nginx/certs/$DOMAIN" ]; then
            info "-> 正在移除安装的证书目录 /etc/nginx/certs/$DOMAIN..."
            rm -rf "/etc/nginx/certs/$DOMAIN"
        fi
        if [ -d "$WP_PATH" ]; then
            info "-> 正在删除 WordPress 目录 $WP_PATH..."
            rm -rf "$WP_PATH"
        fi
        if [ -n "$DB_NAME" ]; then
            info "-> 正在删除数据库 $DB_NAME..."
            mysql -u root -e "DROP DATABASE IF EXISTS \`$DB_NAME\`;"
        fi
        if [ -n "$DB_USER" ]; then
            info "-> 正在删除数据库用户 $DB_USER..."
            mysql -u root -e "DROP USER IF EXISTS '$DB_USER'@'localhost';"
        fi
        info "-> 正在重载 Nginx 并清理配置文件..."
        nginx -t && systemctl reload nginx
        if [ -f "$CONFIG_FILE" ]; then rm -rf "$(dirname "$CONFIG_FILE")"; fi
        info "相关组件卸载完成。/ Related components have been uninstalled."
    fi

    warn "现在，您可以选择是否彻底清除本脚本安装的核心软件包。"
    read -p "您想完全卸载 Nginx, MariaDB, PHP 等软件包吗？(y/N): " purge_packages
    if [[ "$purge_packages" == "y" || "$purge_packages" == "Y" ]]; then
        info "正在清除软件包..."
        # Use OS-specific purge command and package list, use the determined PHP_FPM_SERVICE_UNINSTALL
        # To purge PHP, we need to generalize 'phpX.Y-fpm' to 'php*' for purge command
        $PKG_CMD_PURGE nginx mariadb-server "${PHP_FPM_SERVICE_UNINSTALL::-4}"* php-mysql php-curl php-gd php-mbstring php-xml php-xmlrpc php-soap php-intl php-zip php-imagick php-bcmath wget curl socat
        info "软件包已清除。/ Packages purged."
    fi

    info "--------------------------------------------------------"
    info "卸载完成。"
    info "--------------------------------------------------------"
}


# ==============================================================================
# 脚本入口点 / SCRIPT ENTRY POINT
# ==============================================================================
main() {
    ensure_bash
    check_root
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
