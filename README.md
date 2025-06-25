# WordPress LEMP 自动化脚本

这是一个 Bash 脚本，用于在 Ubuntu/Debian 系统上**自动化安装和卸载 WordPress LEMP (Nginx, MariaDB, PHP) 环境**。它支持灵活的 SSL 配置，包括自动申请 Let's Encrypt 证书。

## 如何使用

将脚本下载或复制到您的服务器上，例如保存为 `wordpress_install.sh`。
给予脚本执行权限：

```bash
chmod +x wordpress_install.sh
```

### 安装 WordPress

运行以下命令并按提示操作：

```bash
sudo bash wordpress_install.sh install
```

脚本将开始交互式地询问您以下信息：

**域名** (例如 `example.com`)

**WordPress 管理员邮箱**

**WordPress 站点标题**

**WordPress 管理员用户名**

**WordPress 管理员密码** (需要确认)

**WordPress 数据库名称**

**数据库用户名**

**数据库密码** (需要确认)

脚本将自动处理软件包安装、服务配置、WordPress 文件下载和数据库设置。在 SSL 配置步骤，请根据提示选择合适的证书选项。

### 卸载 WordPress

运行以下命令：

```bash
sudo bash wordpress_install.sh uninstall
```

卸载程序会尝试自动发现 WordPress 实例。它会询问您确认要卸载的网站路径，并提供是否彻底清除 Nginx、MariaDB 和 PHP 软件包的选项。

**警告：卸载将永久删除所有网站数据和配置，请务必提前备份！**

## 注意事项

* **MariaDB `root` 密码：** 脚本默认尝试以 `root` 用户连接 MariaDB 而无需密码（这在刚安装的系统上很常见）。如果您的 `root` 用户已设置密码，您可能需要先手动配置 `~/.my.cnf` 或在运行脚本前确保 `root` 用户可以无密码登录，或者根据您的 MariaDB 安全设置调整脚本中的 `mysql -u root` 命令。

* **DNS 解析：** 自动申请 SSL 前，请确保您的域名已正确解析到服务器 IP。

* **数据库安全：** 安装后，建议运行 `sudo mysql_secure_installation` 进一步加固 MariaDB 安全。
