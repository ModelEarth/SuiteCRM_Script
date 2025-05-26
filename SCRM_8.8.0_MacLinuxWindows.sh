#!/bin/bash

# TODO: Set parameter with version = "8-8-0" and include prompt to change.

# Function to request user input
get_input() {
    read -p "$1: " value
    echo $value
}

# Detect platform
platform="$(uname)"
case "$platform" in
  Darwin*)
    echo "Platform detected: macOS"
    os="macos"
    ;;
  Linux*)
    echo "Platform detected: Linux"
    os="linux"
    ;;
  CYGWIN*|MINGW*|MSYS*)
    echo "Platform detected: Windows (Git Bash or Cygwin)"
    os="windows"
    ;;
  *)
    echo "Unsupported platform: $platform"
    exit 1
    ;;
esac

# Check if running as root
if [[ "$EUID" -eq 0 ]]; then
    IS_ROOT=true
else
    IS_ROOT=false
fi

# Function to automatically get the internal IP
get_internal_ip() {
  if command -v ip > /dev/null; then
    # Linux (ip command available)
    ip -4 addr show | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v '^127' | head -n1
  elif command -v ifconfig > /dev/null; then
    # macOS or older Linux
    ifconfig | grep -E 'inet (addr:)?' | grep -v '127.0.0.1' | \
      awk '{ print $2 }' | sed 's/addr://' | head -n1
  elif [[ "$OSTYPE" == "msys" || "$OSTYPE" == "cygwin" ]]; then
    # Windows Git Bash or Cygwin
    ipconfig | grep -E "IPv4.*: " | grep -v '127.0.0.1' | \
      sed -E 's/.*:\s*([0-9\.]+)/\1/' | head -n1
  else
    echo "Unsupported OS" >&2
    return 1
  fi
}

# Safe wrapper for Homebrew commands — skips if running as root
brew_safe() {
  if [[ "$EUID" -eq 0 ]]; then
    echo "⚠️ Skipping: brew $* (Homebrew cannot run as root)"
  else
    brew "$@"
  fi
}

# Function to restart services properly based on user privileges
restart_services() {
    echo "🔄 Restarting services..."
    
    if [[ "$IS_ROOT" == true ]]; then
        echo "⚠️ Cannot restart Homebrew services as root. Manual restart required."
        echo "Please open a new terminal as your regular user and run:"
        echo "  brew services restart httpd"
        echo "  brew services restart mariadb"
        echo ""
        read -p "Press Enter after you have restarted the services, or 's' to skip: " skip_restart
        if [[ "$skip_restart" =~ ^[Ss]$ ]]; then
            echo "⚠️ Services not restarted. You may need to restart them manually later."
        fi
    else
        brew services restart httpd || echo "⚠️ Failed to restart Apache"
        brew services restart mariadb || echo "⚠️ Failed to restart MariaDB"
        echo "✅ Services restarted successfully."
    fi
}

# Function to check MariaDB root password status
check_mysql_root_status() {
    echo "🔍 Checking MariaDB root access..."
    
    # Try to connect without password first
    if mysql -u root -e "SELECT 1" &>/dev/null; then
        echo "✅ MariaDB root access confirmed (no password set)."
        ROOT_PASS_SET=false
        MYSQL_ROOT_PASS=""
    else
        # Try with empty password explicitly
        if mysql -u root -p'' -e "SELECT 1" &>/dev/null; then
            echo "✅ MariaDB root access confirmed (empty password)."
            ROOT_PASS_SET=false
            MYSQL_ROOT_PASS=""
        else
            echo "🔑 MariaDB root password appears to be set."
            ROOT_PASS_SET=true
            read -sp "Enter MariaDB root password: " MYSQL_ROOT_PASS
            echo ""
            
            # Test the password
            if ! mysql -u root -p"$MYSQL_ROOT_PASS" -e "SELECT 1" &>/dev/null; then
                echo "❌ Invalid root password. Database configuration failed."
                exit 1
            fi
            echo "✅ MariaDB root password verified."
        fi
    fi
}

# Enhanced database configuration with proper permissions
configure_database_enhanced() {
    echo "🔧 Configuring database with enhanced permissions..."
    
    # First, check if MariaDB is running
    if ! pgrep -f "mysql" > /dev/null; then
        echo "❌ MariaDB is not running. Cannot continue with database setup."
        if [[ "$IS_ROOT" == false ]]; then
            echo "Attempting to start MariaDB..."
            brew services start mariadb || {
                echo "❌ Failed to start MariaDB."
                exit 1
            }
            # Wait a moment for MariaDB to start
            sleep 3
        else
            echo "Please start MariaDB manually and re-run this section."
            exit 1
        fi
    fi

    # Check MariaDB root status
    check_mysql_root_status

    # Configure database with proper error handling
    echo "🔧 Creating database and user..."
    
    if [[ "$ROOT_PASS_SET" == false ]]; then
        MYSQL_CMD="mysql -u root"
    else
        MYSQL_CMD="mysql -u root -p$MYSQL_ROOT_PASS"
    fi

    # Create database and user with comprehensive permissions
    if ! $MYSQL_CMD <<EOF
CREATE DATABASE IF NOT EXISTS CRM CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
DROP USER IF EXISTS '$db_user'@'localhost';
CREATE USER '$db_user'@'localhost' IDENTIFIED BY '$db_pass';
GRANT ALL PRIVILEGES ON CRM.* TO '$db_user'@'localhost';
GRANT SELECT, INSERT, UPDATE, DELETE, CREATE, DROP, INDEX, ALTER, CREATE TEMPORARY TABLES, LOCK TABLES ON CRM.* TO '$db_user'@'localhost';
FLUSH PRIVILEGES;
EOF
    then
        echo "❌ Failed to configure database. Check MariaDB status and permissions."
        exit 1
    fi

    # Verify database creation
    if ! $MYSQL_CMD -e "USE CRM" &>/dev/null; then
        echo "❌ Failed to access database CRM."
        exit 1
    else
        echo "✅ Database CRM created and accessible."
    fi

    # Comprehensive user verification
    if ! $MYSQL_CMD -e "SELECT User FROM mysql.user WHERE User='$db_user';" | grep -q "$db_user"; then
        echo "❌ Failed to create user $db_user."
        exit 1
    else
        echo "✅ User $db_user created successfully."
        
        # Verify comprehensive permissions with better error handling
        echo "🔍 Verifying user permissions..."
        GRANTS=$($MYSQL_CMD -e "SHOW GRANTS FOR '$db_user'@'localhost';" 2>/dev/null || echo "")
        
        if [[ -z "$GRANTS" ]]; then
            echo "⚠️ Warning: Could not retrieve user permissions."
            echo "📋 Manual verification steps:"
            echo "   1. Connect to MariaDB: mysql -u root -p"
            echo "   2. Run: SHOW GRANTS FOR '$db_user'@'localhost';"
            echo "   3. Verify the user has ALL PRIVILEGES on CRM database"
            echo "   4. If permissions are missing, run:"
            echo "      GRANT ALL PRIVILEGES ON CRM.* TO '$db_user'@'localhost';"
            echo "      FLUSH PRIVILEGES;"
        elif echo "$GRANTS" | grep -q "GRANT ALL PRIVILEGES ON \`CRM\`"; then
            echo "✅ User $db_user has full privileges on CRM database."
        elif echo "$GRANTS" | grep -q "ON \`CRM\`"; then
            echo "✅ User $db_user has permissions on CRM database."
            echo "📋 Granted permissions:"
            echo "$GRANTS" | grep "CRM"
        else
            echo "⚠️ Warning: Could not verify user permissions."
            echo "📋 Manual verification steps:"
            echo "   1. Connect to MariaDB: mysql -u root -p"
            echo "   2. Run: SHOW GRANTS FOR '$db_user'@'localhost';"
            echo "   3. Verify the user has ALL PRIVILEGES on CRM database"
            echo "   4. Current grants output:"
            echo "$GRANTS"
        fi
    fi

    # Test user connection
    echo "🔍 Testing user database connection..."
    if mysql -u "$db_user" -p"$db_pass" -e "USE CRM; SELECT 'Connection successful' as Status;" &>/dev/null; then
        echo "✅ User database connection test successful."
    else
        echo "❌ User cannot connect to database. Please check credentials and permissions."
        echo "📋 Troubleshooting steps:"
        echo "   1. Verify MariaDB is running: brew services list | grep mariadb"
        echo "   2. Test root connection: mysql -u root -p"
        echo "   3. Check user exists: SELECT User FROM mysql.user WHERE User='$db_user';"
        echo "   4. Reset user password: ALTER USER '$db_user'@'localhost' IDENTIFIED BY '$db_pass';"
        exit 1
    fi
}

# Enhanced MySQL security setup
setup_mysql_security() {
    echo "🔒 Setting up MySQL security..."
    
    # Re-check root password status after potential mysql_secure_installation
    check_mysql_root_status
    
    if [[ "$ROOT_PASS_SET" == false ]]; then
        echo "⚠️ MariaDB root password is not set. This is a security risk."
        read -p "Would you like to run mysql_secure_installation now? [Y/n]: " run_secure
        
        if [[ ! "$run_secure" =~ ^[Nn]$ ]]; then
            echo "🔒 Running mysql_secure_installation..."
            echo "Please follow the prompts to secure your MariaDB installation."
            echo "Recommended answers: Y, Y, Y, Y, Y"
            echo ""
            
            if command -v mysql_secure_installation &>/dev/null; then
                mysql_secure_installation || {
                    echo "⚠️ mysql_secure_installation encountered issues. Please run it manually later."
                }
                
                # After running mysql_secure_installation, update the root password status
                echo "🔍 Re-checking MariaDB root status after security setup..."
                check_mysql_root_status
                
            else
                echo "❌ mysql_secure_installation not found. Please run it manually:"
                echo "sudo $(brew --prefix)/bin/mysql_secure_installation"
            fi
        else
            echo "⚠️ Skipping MySQL security setup. Remember to run 'mysql_secure_installation' later."
        fi
    else
        echo "✅ MariaDB root password is already set."
    fi
}

# Function to check and fix Apache configuration
check_apache_config() {
    echo "🔍 Checking Apache configuration..."
    
    # Test Apache configuration
    if ! httpd -t &>/dev/null; then
        echo "❌ Apache configuration has errors. Checking common issues..."
        
        # Check if the configuration file exists
        if [ ! -f "$HTTPD_CONF" ]; then
            echo "❌ Apache configuration file not found at $HTTPD_CONF"
            return 1
        fi
        
        # Check for common issues and fix them
        echo "🔧 Attempting to fix common Apache configuration issues..."
        
        # Fix ServerRoot if needed
        if ! grep -q "^ServerRoot" "$HTTPD_CONF"; then
            echo "ServerRoot /opt/homebrew/var" >> "$HTTPD_CONF"
        fi
        
        # Ensure PidFile directory exists
        PIDFILE_DIR=$(grep "^PidFile" "$HTTPD_CONF" | cut -d' ' -f2 | xargs dirname 2>/dev/null || echo "/opt/homebrew/var/run")
        if [ ! -d "$PIDFILE_DIR" ]; then
            mkdir -p "$PIDFILE_DIR" || sudo mkdir -p "$PIDFILE_DIR"
        fi
        
        # Test again
        if ! httpd -t &>/dev/null; then
            echo "❌ Apache configuration still has errors. Please check manually:"
            echo "   Run: httpd -t"
            echo "   Check error logs: tail -f /opt/homebrew/var/log/httpd/error_log"
            return 1
        fi
    fi
    
    echo "✅ Apache configuration is valid."
    return 0
}

# Function to check if Apache is actually running and accessible
check_apache_status() {
    echo "🔍 Checking Apache status..."
    
    # Check if Apache process is running
    if ! pgrep -f "httpd" > /dev/null; then
        echo "❌ Apache is not running."
        return 1
    fi
    
    # Check if Apache is listening on port 8080
    if ! netstat -an | grep -q ":8080.*LISTEN"; then
        echo "❌ Apache is not listening on port 8080."
        echo "📋 Troubleshooting steps:"
        echo "   1. Check Apache configuration: httpd -t"
        echo "   2. Check Apache error log: tail -f /opt/homebrew/var/log/httpd/error_log"
        echo "   3. Try restarting Apache: brew services restart httpd"
        return 1
    fi
    
    echo "✅ Apache is running and listening on port 8080."
    return 0
}

# Request user information
echo ""
echo "Choose where to set up your SuiteCRM database:"
echo "1 - Azure (remotely)"
echo "2 - MariaDB (locally)"
read -p "Enter your choice [1/2]: " db_choice

if [[ "$db_choice" == "1" ]]; then
    echo "🧭 Azure setup selected."
    read -p "Enter Azure MySQL host (e.g., your-db.mysql.database.azure.com): " azure_host
    read -p "Enter Azure DB name: " azure_db
    read -p "Enter Azure DB username (e.g., suitecrm_user@your-db): " azure_user
    read -sp "Enter Azure DB password: " azure_pass
    echo ""
    echo "🔧 Azure setup is currently under development."
    echo "➡️ Please manually run the Azure SQL script or configure DB access in SuiteCRM installer."
    exit 0
fi

# If not Azure, proceed with local MariaDB as usual
read -p "Enter your MariaDB username: " db_user
read -sp "Enter your MariaDB password: " db_pass
echo ""

# Automatically get the internal IP
server_ip=$(get_internal_ip)
echo "IP retrieved: $server_ip"

# Function to install a package if not already installed
install_if_missing() {
  if ! brew_safe list "$1" &>/dev/null; then
    echo "📦 Installing $1..."
    brew_safe install "$1"
  else
    echo "✅ $1 is already installed."
  fi
}

install_php_macos() {
    # Install PHP 8.2 and common extensions
    echo "📦 Installing PHP 8.2 and extensions..."
    if [[ "$EUID" -eq 0 ]]; then
        echo "❌ Cannot install PHP as root via Homebrew."
        echo "➡️ Please re-run this script as a normal user to install PHP."
        exit 1
    fi
    brew_safe install php@8.2

    # Add PHP 8.2 to PATH if not already in it
    PHP82_PATH="/opt/homebrew/opt/php@8.2/bin"
    if ! echo "$PATH" | grep -q "$PHP82_PATH"; then
      echo "🔧 Updating PATH to use PHP 8.2..."
      echo 'export PATH="/opt/homebrew/opt/php@8.2/bin:$PATH"' >> ~/.zprofile
      echo 'export PATH="/opt/homebrew/opt/php@8.2/sbin:$PATH"' >> ~/.zprofile
      export PATH="/opt/homebrew/opt/php@8.2/bin:$PATH"
      export PATH="/opt/homebrew/opt/php@8.2/sbin:$PATH"
    fi

    # Link PHP 8.2 as the default
    brew_safe link --overwrite --force php@8.2

    # Common PHP extensions (included or installable via PECL)
    echo "📦 Installing PECL and common PHP extensions..."
    brew_safe install autoconf pkg-config
    pecl install imagick || true
    pecl install ldap || true
    pecl install imap || true
    pecl install soap || true
    pecl install bcmath || true

    echo "✅ PHP 8.2 and common extensions are installed."
    # Show installed PHP version
    if ! command -v php > /dev/null; then
        echo "❌ PHP is still not installed. Aborting."
        echo "➡️ Please run the script without sudo so Homebrew can install PHP."
        exit 1
    else
        php -v
    fi
}
install_php_PC() {
    echo "📦 Installing PHP 8.2 for Windows (Git Bash or Cygwin)..."

    # Assuming Chocolatey is installed — check if not, guide user
    if ! command -v choco &> /dev/null; then
        echo "⚠️ Chocolatey not found. Please install Chocolatey first: https://chocolatey.org/install"
        return 1
    fi

    # Install PHP via Chocolatey
    choco install php --version=8.2 -y

    # Optional: Add PHP to PATH
    PHP_PATH="/c/tools/php82"
    if ! echo "$PATH" | grep -q "$PHP_PATH"; then
        echo "🔧 Please manually add PHP 8.2 to your Windows PATH or restart Git Bash after installation."
    fi

    # Show PHP version
    php -v
}


# Configuration for MacOS, Linux and Windows
if [[ "$os" == "macos" ]]; then
    
    echo "Platform detected: macOS - Beginning setup process..."
    
    # Check for Homebrew installation
    echo "🔍 Checking for Homebrew..."
    if ! command -v brew &> /dev/null; then
      if [[ "$IS_ROOT" == true ]]; then
        echo "❌ Homebrew not found and cannot be installed as root."
        echo "Please install Homebrew as a regular user first: https://brew.sh"
        exit 1
      fi
      
      echo "🍺 Homebrew not found. Installing..."
      /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" || {
        echo "❌ Failed to install Homebrew. Please install it manually: https://brew.sh"
        exit 1
      }
      
      # Add Homebrew to PATH if not already there
      if [[ "$(uname -m)" == "arm64" ]]; then
        echo 'eval "$(/opt/homebrew/bin/brew shellenv)"' >> ~/.zprofile
        eval "$(/opt/homebrew/bin/brew shellenv)"
      else
        echo 'eval "$(/usr/local/bin/brew shellenv)"' >> ~/.zprofile
        eval "$(/usr/local/bin/brew shellenv)"
      fi
    else
      echo "✅ Homebrew is already installed."
    fi

    # Function for installing packages
    install_package() {
      local package=$1
      echo "📦 Installing $package..."
      if ! brew_safe list "$package" &>/dev/null; then
        brew_safe install "$package" || {
          echo "❌ Failed to install $package."
          return 1
        }
        echo "✅ $package installed successfully."
      else
        echo "✅ $package is already installed."
      fi
      return 0
    }

    # Update and upgrade Homebrew
    if [[ "$IS_ROOT" == false ]]; then
        echo "🔄 Updating Homebrew and packages..."
        brew update && brew upgrade || {
          echo "⚠️ Warning: Failed to update Homebrew. Continuing anyway..."
        }
    fi

    # Install essential packages
    install_package wget || exit 1
    install_package unzip || exit 1

    # Install PHP 8.2 if not already installed or update if needed
    CURRENT_PHP=""
    if command -v php >/dev/null 2>&1; then
      CURRENT_PHP="$(php -v | head -n 1 | awk '{print $2}')"
    fi
    
    if [ -n "$CURRENT_PHP" ]; then
        if [[ "$CURRENT_PHP" != 8.2* ]]; then
          echo "⚠️ Detected PHP version: $CURRENT_PHP"
          echo "Switching to PHP 8.2 may affect your local development environment."
          read -p "Do you want to continue and install/switch to PHP 8.2? [y/N]: " confirm
          if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
            echo "Not updating PHP"
          else
            echo "Starting PHP update process"
            install_php_macos || {
              echo "❌ Failed to install PHP 8.2"
              exit 1
            }
          fi
        else
          echo "✅ PHP 8.2 is already installed."
        fi
    else
        install_php_macos || {
          echo "❌ Failed to install PHP 8.2"
          exit 1
        }
    fi

    # Install and configure Apache
    echo "🔧 Installing and configuring Apache Server..."
    install_package httpd || exit 1

    # Start Apache service with error handling
    # echo "🔧 Starting Apache service..."
    # if [[ "$IS_ROOT" == false ]]; then
    #    brew services start httpd || {
    #      echo "⚠️ Failed to start Apache service. Attempting to restart..."
    #      brew services restart httpd || {
    #        echo "❌ Failed to start Apache. Please check the Apache configuration."
    #        exit 1
    #      }
    #    }
    # else
    #    echo "⚠️ Cannot start Apache service as root. Manual start required."
    # fi

    # Define Apache and PHP paths
    HTTPD_CONF="/opt/homebrew/etc/httpd/httpd.conf"
    HTTPD_VHOSTS="/opt/homebrew/etc/httpd/extra/httpd-vhosts.conf"
    PHP_CONF="/opt/homebrew/etc/httpd/extra/httpd-php.conf"
    PHP_INI="/opt/homebrew/etc/php/8.2/php.ini"
    
    # Check if paths exist, adjust for Intel Macs if needed
    if [ ! -f "$HTTPD_CONF" ]; then
      HTTPD_CONF="/usr/local/etc/httpd/httpd.conf"
      HTTPD_VHOSTS="/usr/local/etc/httpd/extra/httpd-vhosts.conf"
      PHP_CONF="/usr/local/etc/httpd/extra/httpd-php.conf"
      PHP_INI="/usr/local/etc/php/8.2/php.ini"
    fi

    # Create backups of configuration files
    if [ -f "$HTTPD_CONF" ]; then
      echo "🔧 Creating backup of Apache configuration..."
      cp "$HTTPD_CONF" "${HTTPD_CONF}.bak" || {
        echo "⚠️ Failed to create backup of Apache configuration."
      }
    else
      echo "❌ Apache configuration file not found at $HTTPD_CONF"
      exit 1
    fi

    # Configure Apache modules and PHP integration
    echo "🔧 Configuring Apache modules..."
    if [ -f "$HTTPD_CONF" ]; then
        # Enable mod_rewrite
        sed -i '' 's/#LoadModule rewrite_module/LoadModule rewrite_module/g' "$HTTPD_CONF"
        
        # Enable PHP module
        if ! grep -q "LoadModule php_module" "$HTTPD_CONF"; then
            PHP_MODULE=$(find /opt/homebrew/opt/php@8.2 -name "libphp.so" 2>/dev/null || find /usr/local/opt/php@8.2 -name "libphp.so" 2>/dev/null)
            if [ -n "$PHP_MODULE" ]; then
                echo "LoadModule php_module $PHP_MODULE" >> "$HTTPD_CONF"
                echo "✅ PHP module enabled in Apache configuration."
            else
                echo "⚠️ PHP module not found. PHP may not work correctly with Apache."
            fi
        fi
        
        # Add PHP handling if not already configured
        if ! grep -q "FilesMatch \\.php$" "$HTTPD_CONF"; then
            cat << EOF >> "$HTTPD_CONF"
<FilesMatch \.php$>
    SetHandler application/x-httpd-php
</FilesMatch>
DirectoryIndex index.php index.html
EOF
            echo "✅ PHP handler configuration added."
        fi
        
        # Disable directory listing globally
        sed -i '' 's/Options Indexes FollowSymLinks/Options -Indexes +FollowSymLinks/g' "$HTTPD_CONF"
        echo "✅ Directory listing disabled."

        # Ensure Apache listens on port 8080
        if ! grep -q "Listen 8080" "$HTTPD_CONF"; then
            sed -i '' 's/Listen 80$/Listen 8080/' "$HTTPD_CONF"
            echo "✅ Apache configured to listen on port 8080."
        else
            echo "⚠️ Apache is NOT configured to listen on port 8080."
        fi
    fi

    # Define document root and directories
    DOCUMENT_ROOT="/opt/homebrew/var/www"
    if [ ! -d "$DOCUMENT_ROOT" ]; then
        DOCUMENT_ROOT="/usr/local/var/www"
        if [ ! -d "$DOCUMENT_ROOT" ]; then
            echo "🔧 Creating document root directory..."
            mkdir -p "$DOCUMENT_ROOT" || sudo mkdir -p "$DOCUMENT_ROOT"
        fi
    fi
    
    CRM_ROOT="$DOCUMENT_ROOT/crm"
    
    # Create directories if they don't exist
    echo "🔧 Creating CRM directories..."
    mkdir -p "$CRM_ROOT" || {
        echo "⚠️ Failed to create $CRM_ROOT directory. Trying with sudo..."
        sudo mkdir -p "$CRM_ROOT" || {
            echo "❌ Failed to create CRM directory. Check permissions."
            exit 1
        }
    }
    
    # Download and install SuiteCRM
    echo "🔧 Installing and configuring SuiteCRM..."
    cd "$CRM_ROOT" || {
        echo "❌ Failed to change to CRM directory."
        exit 1
    }
    
    # Download SuiteCRM if not already present
    if [ ! -f "suitecrm-8-8-0.zip" ]; then
        echo "📦 Downloading SuiteCRM..."
        wget https://suitecrm.com/download/148/suite87/564667/suitecrm-8-8-0.zip || {
            echo "❌ Failed to download SuiteCRM."
            exit 1
        }
    else
        echo "✅ SuiteCRM archive already exists, using cached version."
    fi
    
    # Extract SuiteCRM
    echo "📦 Extracting SuiteCRM..."
    unzip -o suitecrm-8-8-0.zip || {
        echo "❌ Failed to extract SuiteCRM."
        exit 1
    }
    echo "✅ SuiteCRM extracted successfully."
    
    # Set permissions
    echo "🔧 Setting permissions..."
    CURRENT_USER=$(whoami)
    GROUP=$(id -gn)
    
    # Set ownership and permissions
    sudo chown -R "$CURRENT_USER:$GROUP" "$CRM_ROOT" || {
        echo "⚠️ Failed to set ownership on CRM directory."
    }
    
    # Set directory and file permissions
    find "$CRM_ROOT" -type d -exec chmod 750 {} \; || {
        echo "⚠️ Failed to set directory permissions."
    }
    find "$CRM_ROOT" -type f -exec chmod 640 {} \; || {
        echo "⚠️ Failed to set file permissions."
    }
    
    # Make sure executable files stay executable
    if [ -f "$CRM_ROOT/bin/console" ]; then
        chmod +x "$CRM_ROOT/bin/console" || {
            echo "⚠️ Failed to make console script executable."
        }
    fi
    
    # Make storage directories writable
    if [ -d "$CRM_ROOT/storage" ]; then
        chmod -R 770 "$CRM_ROOT/storage" || {
            echo "⚠️ Failed to set storage directory permissions."
        }
    fi
    if [ -d "$CRM_ROOT/cache" ]; then
        chmod -R 770 "$CRM_ROOT/cache" || {
            echo "⚠️ Failed to set cache directory permissions."
        }
    fi

    # Configure Virtual Host
    echo "🔧 Configuring VirtualHost..."
    
    # Make sure vhosts directory exists
    VHOSTS_DIR=$(dirname "$HTTPD_VHOSTS")
    if [ ! -d "$VHOSTS_DIR" ]; then
        mkdir -p "$VHOSTS_DIR" || sudo mkdir -p "$VHOSTS_DIR" || {
            echo "❌ Failed to create vhosts directory."
            exit 1
        }
    fi
    
    # Enable vhosts module in main config
    sed -i '' 's/#Include.*httpd-vhosts.conf/Include \/opt\/homebrew\/etc\/httpd\/extra\/httpd-vhosts.conf/g' "$HTTPD_CONF" || {
        # Try Intel Mac path
        sed -i '' 's/#Include.*httpd-vhosts.conf/Include \/usr\/local\/etc\/httpd\/extra\/httpd-vhosts.conf/g' "$HTTPD_CONF" || {
            echo "⚠️ Failed to enable vhosts in Apache config. Manual configuration may be required."
        }
    }
    
    # Create VirtualHost configuration with security headers
    DOCUMENT_ROOT_ESC=$(echo "$DOCUMENT_ROOT" | sed 's/[\/&]/\\&/g')
    CRM_ROOT_ESC=$(echo "$CRM_ROOT" | sed 's/[\/&]/\\&/g')
    
    cat << EOF > "$HTTPD_VHOSTS"
# Default virtual host (respond to any unmatched requests)
<VirtualHost *:8080>
    DocumentRoot "$DOCUMENT_ROOT"
    ServerName localhost
</VirtualHost>

# CRM virtual host
<VirtualHost *:8080>
    ServerAdmin admin@example.com
    DocumentRoot "$CRM_ROOT/public"
    ServerName $server_ip
    
    <Directory "$CRM_ROOT/public">
        Options -Indexes +FollowSymLinks +MultiViews
        AllowOverride All
        Require all granted
    </Directory>
    
    ErrorLog /opt/homebrew/var/log/httpd/crm-error_log
    CustomLog /opt/homebrew/var/log/httpd/crm-access_log combined
    
    # Security headers
    Header always set X-Content-Type-Options "nosniff"
    Header always set X-XSS-Protection "1; mode=block"
    Header always set X-Frame-Options "SAMEORIGIN"
</VirtualHost>
EOF

    # Enable headers module for security headers
    sed -i '' 's/#LoadModule headers_module/LoadModule headers_module/g' "$HTTPD_CONF" || {
        echo "⚠️ Failed to enable headers module in Apache config."
    }

    # Configure php.ini
    echo "🔧 Setting php.ini..."
    if [ -f "$PHP_INI" ]; then
        # Make backup of original php.ini
        cp "$PHP_INI" "${PHP_INI}.bak" || {
            echo "⚠️ Failed to create backup of php.ini"
        }
        
        # Update PHP settings
        sed -i '' 's/memory_limit = .*/memory_limit = 512M/' "$PHP_INI" || echo "⚠️ Failed to set memory_limit"
        sed -i '' 's/upload_max_filesize = .*/upload_max_filesize = 50M/' "$PHP_INI" || echo "⚠️ Failed to set upload_max_filesize"
        sed -i '' 's/post_max_size = .*/post_max_size = 50M/' "$PHP_INI" || echo "⚠️ Failed to set post_max_size"
        sed -i '' 's/max_execution_time = .*/max_execution_time = 300/' "$PHP_INI" || echo "⚠️ Failed to set max_execution_time"
        
        # Add security settings
        sed -i '' 's/display_errors = .*/display_errors = Off/' "$PHP_INI" || echo "⚠️ Failed to set display_errors"
        sed -i '' 's/expose_php = .*/expose_php = Off/' "$PHP_INI" || echo "⚠️ Failed to set expose_php"
        
        echo "✅ PHP configuration updated."
    else
        echo "⚠️ PHP config file not found at $PHP_INI"
    fi
    
    # Install and configure MariaDB
    echo "🔧 Installing MariaDB..."
    install_package mariadb || exit 1

    # Start MariaDB service with error handling
    if ! pgrep -f "mysql" > /dev/null; then
        echo "🔧 Starting MariaDB service..."
        if [[ "$IS_ROOT" == false ]]; then
            brew services start mariadb || {
              echo "⚠️ Failed to start MariaDB service. Attempting to restart..."
              brew services restart mariadb || {
                echo "❌ Failed to start MariaDB. Please check for errors."
                exit 1
              }
            }
        else
            echo "⚠️ Cannot start MariaDB service as root. Manual start required."
        fi
    fi
    
    # Check if MariaDB is running
    if ! pgrep -f "mysql" > /dev/null; then
        echo "❌ MariaDB is not running. Cannot continue with database setup."
        echo "Please start MariaDB manually and re-run this script."
        exit 1
    else
        echo "✅ MariaDB is running."
    fi

    # Enhanced database configuration
    configure_database_enhanced

    # Setup MySQL security
    setup_mysql_security
    
    # Restart services with proper handling
    restart_services
    
    # Create a simple health check
    echo "<?php echo 'CRM Health Check: ' . date('Y-m-d H:i:s'); ?>" > "$CRM_ROOT/public/health.php"
    chmod 644 "$CRM_ROOT/public/health.php" || {
        echo "⚠️ Failed to create health check file."
    }
    
    echo ""
    echo "🎉 macOS setup completed successfully!"
    echo "📝 You can now complete the installation of your CRM at: http://$server_ip:8080"
    echo "👉 Health check URL: http://$server_ip:8080/health.php"
    echo ""
    echo "📋 Configuration summary:"
    echo "  - Database: CRM"
    echo "  - Database User: $db_user (with full privileges)"
    echo "  - Server IP: $server_ip"
    echo "  - Document Root: $CRM_ROOT"
    echo "  - Apache port: 8080 (Homebrew default)"
    echo ""
    
    if [[ "$IS_ROOT" == true ]]; then
        echo "⚠️ IMPORTANT - Manual steps required (script was run as root):"
        echo "1. Switch to your regular user account"
        echo "2. Run: brew services restart httpd"
        echo "3. Run: brew services restart mariadb"
        echo ""
    fi
    
    echo "🔒 Security recommendations:"
    if [[ "$ROOT_PASS_SET" == false ]]; then
        echo "  - Run 'mysql_secure_installation' to secure MariaDB"
    fi
    echo "  - Consider setting up SSL/TLS certificates for production use"
    echo "  - Review and customize Apache security settings as needed"

elif [[ "$os" == "windows" ]]; then

    echo "Platform detected: Windows (Git Bash or Cygwin) - Beginning setup process..."

    # Check for administrative privileges
    if ! net session &>/dev/null; then
        echo "❌ This script requires administrative privileges on Windows."
        echo "Please right-click on Git Bash and select 'Run as administrator', then try again."
        exit 1
    fi

    # Check for Chocolatey
    if ! command -v choco &> /dev/null; then
        echo "⚠️ Chocolatey not found. Please install Chocolatey first:"
        echo "Run PowerShell as Administrator and execute:"
        echo "Set-ExecutionPolicy Bypass -Scope Process -Force; [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072; iex ((New-Object System.Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))"
        exit 1
    else
        echo "✅ Chocolatey is installed."
    fi

    # Define base paths with proper Windows path handling
    APACHE_PATH=$(cygpath -w "/c/tools/apache24" | sed 's/\\/\//g')
    PHP_PATH=$(cygpath -w "/c/tools/php82" | sed 's/\\/\//g')
    DOCUMENT_ROOT="$APACHE_PATH/htdocs"
    CRM_ROOT="$DOCUMENT_ROOT/crm"
    
    # Configuration files
    APACHE_CONF="$APACHE_PATH/conf/httpd.conf"
    APACHE_VHOSTS="$APACHE_PATH/conf/extra/httpd-vhosts.conf"
    PHP_INI="$PHP_PATH/php.ini"
    PHP_INI_DEVELOPMENT="$PHP_PATH/php.ini-development"

    # Install essential packages with error handling
    echo "📦 Installing essential tools..."
    choco install wget unzip -y || {
        echo "❌ Failed to install essential tools. Please check your internet connection."
        exit 1
    }

    # Install Apache HTTP Server
    echo "📦 Installing Apache HTTP Server..."
    if ! choco list --local-only | grep -q apache-httpd; then
        choco install apache-httpd -y || {
            echo "❌ Failed to install Apache HTTP Server."
            exit 1
        }
    else
        echo "✅ Apache HTTP Server is already installed."
    fi

    # Install PHP with improved handling
    echo "📦 Installing PHP 8.2..."
    install_php_PC || {
        echo "❌ Failed to install PHP 8.2."
        exit 1
    }

    # Verify PHP installation
    if ! command -v php &> /dev/null; then
        echo "❌ PHP installation failed or PHP is not in PATH."
        echo "Please add PHP to your PATH and try again."
        exit 1
    else
        PHP_VERSION=$(php -v | head -n 1 | awk '{print $2}')
        echo "✅ PHP $PHP_VERSION installed successfully."
    fi

    # Configure PHP for Apache
    echo "🔧 Configuring PHP with Apache..."
    if [ -f "$APACHE_CONF" ]; then
        # Create backup of Apache config
        cp "$APACHE_CONF" "${APACHE_CONF}.bak" || {
            echo "⚠️ Failed to create backup of Apache config."
        }
        
        # Check if PHP module is already configured
        if ! grep -q "LoadModule php_module" "$APACHE_CONF"; then
            echo "LoadModule php_module \"$PHP_PATH/php8apache2_4.dll\"" >> "$APACHE_CONF" || {
                echo "❌ Failed to add PHP module to Apache config."
                exit 1
            }
            echo "AddType application/x-httpd-php .php" >> "$APACHE_CONF"
            echo "PHPIniDir \"$PHP_PATH\"" >> "$APACHE_CONF"
            echo "✅ PHP module added to Apache configuration."
        else
            echo "✅ PHP module already configured in Apache."
        fi
        
        # Enable required modules for CRM
        for MODULE in rewrite headers; do
            if grep -q "#LoadModule ${MODULE}_module" "$APACHE_CONF"; then
                sed -i "s/#LoadModule ${MODULE}_module/LoadModule ${MODULE}_module/" "$APACHE_CONF" || {
                    echo "⚠️ Failed to enable $MODULE module."
                }
                echo "✅ Enabled $MODULE module."
            else
                echo "✅ $MODULE module already enabled."
            fi
        done
        
        # Enable vhosts in main config if needed
        if grep -q "#Include conf/extra/httpd-vhosts.conf" "$APACHE_CONF"; then
            sed -i 's/#Include conf\/extra\/httpd-vhosts.conf/Include conf\/extra\/httpd-vhosts.conf/' "$APACHE_CONF" || {
                echo "⚠️ Failed to enable vhosts configuration."
            }
            echo "✅ Virtual hosts enabled."
        fi
    else
        echo "❌ Apache config file not found at $APACHE_CONF"
        exit 1
    fi

    # Configure php.ini with robust error handling
    echo "🔧 Configuring PHP settings..."
    if [ ! -f "$PHP_INI" ] && [ -f "$PHP_INI_DEVELOPMENT" ]; then
        echo "Creating php.ini from development template..."
        cp "$PHP_INI_DEVELOPMENT" "$PHP_INI" || {
            echo "❌ Failed to create php.ini from template."
            exit 1
        }
    fi
    
    if [ -f "$PHP_INI" ]; then
        # Create backup of php.ini
        cp "$PHP_INI" "${PHP_INI}.bak" || {
            echo "⚠️ Failed to create backup of php.ini"
        }
        
        # Update settings in php.ini with error checking
        echo "🔧 Updating PHP settings..."
        for SETTING in \
            "memory_limit = 512M" \
            "upload_max_filesize = 50M" \
            "post_max_size = 50M" \
            "max_execution_time = 300" \
            "display_errors = Off" \
            "expose_php = Off"; do
            
            SETTING_NAME=$(echo "$SETTING" | cut -d'=' -f1 | tr -d ' ')
            SETTING_VALUE=$(echo "$SETTING" | cut -d'=' -f2)
            
            sed -i "s/^${SETTING_NAME} =.*/${SETTING}/" "$PHP_INI" || {
                echo "⚠️ Failed to set $SETTING_NAME to $SETTING_VALUE"
            }
        done
        
        # Enable required extensions
        for EXT in curl gd mbstring mysqli pdo_mysql soap xml; do
            sed -i "s/;extension=${EXT}/extension=${EXT}/" "$PHP_INI" || {
                echo "⚠️ Failed to enable $EXT extension"
            }
        done
        
        echo "✅ PHP configuration updated."
    else
        echo "❌ PHP config file not found at $PHP_INI"
        exit 1
    fi

    # MariaDB installation with improved error handling
    echo "📦 Installing MariaDB..."
    if ! choco list --local-only | grep -q mariadb; then
        choco install mariadb -y || {
            echo "❌ Failed to install MariaDB."
            exit 1
        }
        
        # Wait for MariaDB to initialize
        echo "⏳ Waiting for MariaDB to initialize..."
        for i in {1..30}; do
            if net start | grep -q "MariaDB"; then
                echo "✅ MariaDB service is running."
                break
            elif [ $i -eq 30 ]; then
                echo "⚠️ Timeout waiting for MariaDB service. Attempting to start it manually..."
                net start MariaDB || {
                    echo "❌ Failed to start MariaDB service. Please start it manually and try again."
                    exit 1
                }
            else
                echo "Waiting for MariaDB service to start ($i/30)..."
                sleep 2
            fi
        done
    else
        echo "✅ MariaDB is already installed."
        
        # Ensure service is running
        if ! net start | grep -q "MariaDB"; then
            echo "⚠️ MariaDB service is not running. Attempting to start..."
            net start MariaDB || {
                echo "❌ Failed to start MariaDB service."
                exit 1
            }
        fi
    fi
    
    # Configure database with robust error handling
    echo "🔧 Configuring main database..."
    if ! mysql -u root -e "SELECT 1" &>/dev/null; then
        echo "❌ Cannot connect to MySQL. Please check if the service is running and credentials are correct."
        exit 1
    fi
    
    # Create database with error checking
    if ! mysql -u root <<EOF
CREATE DATABASE IF NOT EXISTS CRM CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '$db_user'@'localhost' IDENTIFIED BY '$db_pass';
GRANT ALL PRIVILEGES ON CRM.* TO '$db_user'@'localhost';
FLUSH PRIVILEGES;
EOF
    then
        echo "❌ Failed to create database and user."
        exit 1
    fi

    # Verify database was created
    if ! mysql -u root -e "USE CRM"; then
        echo "❌ Failed to create database CRM. Please check MySQL root permissions."
        exit 1
    else
        echo "✅ Database CRM created successfully."
    fi

    # Verify User creation
    if ! mysql -u root -e "SELECT User FROM mysql.user WHERE User='$db_user';" | grep -q "$db_user"; then
        echo "❌ Failed to create user $db_user."
        exit 1
    else
        echo "✅ User $db_user created successfully."
        
        # Additional verification of user permissions
        GRANTS=$(mysql -u root -e "SHOW GRANTS FOR '$db_user'@'localhost';" | grep "ON \`CRM\`\." || echo "")
        if [[ -z "$GRANTS" ]]; then
            echo "⚠️ Warning: User $db_user may not have proper permissions on CRM database."
        else
            echo "✅ User permissions verified."
        fi
    fi

    # Create directories for SuiteCRM with error handling
    echo "🔧 Creating directories for SuiteCRM..."
    mkdir -p "$CRM_ROOT" || {
        echo "❌ Failed to create CRM directory. Check permissions."
        exit 1
    }
    
    # Download and extract SuiteCRM with robust error handling
    echo "📦 Downloading SuiteCRM..."
    cd "$CRM_ROOT" || {
        echo "❌ Failed to change to CRM directory."
        exit 1
    }
    
    if [ ! -f "suitecrm-8-8-0.zip" ]; then
        wget -O suitecrm-8-8-0.zip https://suitecrm.com/download/148/suite87/564667/suitecrm-8-8-0.zip || {
            echo "❌ Failed to download SuiteCRM."
            exit 1
        }
    else
        echo "✅ SuiteCRM archive already exists, using cached version."
    fi
    
    echo "📦 Extracting SuiteCRM..."
    unzip -o suitecrm-8-8-0.zip || {
        echo "❌ Failed to extract SuiteCRM."
        exit 1
    }
    echo "✅ SuiteCRM extracted successfully."

    # Configure VirtualHost with improved security
    echo "🔧 Configuring VirtualHost..."
    if [ -f "$APACHE_CONF" ]; then
        # Make sure the vhosts directory exists
        mkdir -p "$(dirname "$APACHE_VHOSTS")" || {
            echo "⚠️ Failed to create vhosts directory."
            exit 1
        }

        # Create a temporary file to hold the VirtualHost configuration
        tmpfile=$(mktemp) || {
            echo "❌ Failed to create temporary file for VirtualHost config."
            exit 1
        }

        # Write the VirtualHost configuration with security headers
        cat << EOF > "$tmpfile"
<VirtualHost *:80>
    ServerAdmin webmaster@localhost
    DocumentRoot "$CRM_ROOT/public"
    ServerName $server_ip

    <Directory "$CRM_ROOT/public">
        Options -Indexes +FollowSymLinks +MultiViews
        AllowOverride All
        Require all granted
    </Directory>

    ErrorLog logs/crm-error.log
    CustomLog logs/crm-access.log combined

    # Security headers
    Header always set X-Content-Type-Options "nosniff"
    Header always set X-XSS-Protection "1; mode=block"
    Header always set X-Frame-Options "SAMEORIGIN"
</VirtualHost>
EOF

        # Move the temporary file to the final config path
        mv "$tmpfile" "$APACHE_VHOSTS" || {
            echo "❌ Failed to move VirtualHost configuration to $APACHE_VHOSTS."
            exit 1
        }

        echo "✅ VirtualHost configuration created with security headers."
    else
        echo "❌ Failed to configure VirtualHost - Apache config not found at $APACHE_CONF."
        exit 1
    fi


    # Set permissions with Windows compatibility
    echo "🔧 Setting permissions..."
    if command -v icacls &>/dev/null; then
        # Grant appropriate permissions to the Apache user
        APACHE_USER="NETWORK SERVICE"
        
        # Find proper Apache service user
        if net user | grep -q "Apache"; then
            APACHE_USER="Apache"
        fi
        
        # Set permissions - Full control for Apache user, Read/Execute for Everyone
        icacls "$CRM_ROOT" /grant:r "$APACHE_USER:(OI)(CI)F" /grant:r "SYSTEM:(OI)(CI)F" /grant:r "Everyone:(OI)(CI)RX" /T || {
            echo "⚠️ Failed to set Windows permissions with icacls."
            echo "Falling back to simpler permissions..."
            icacls "$CRM_ROOT" /grant Everyone:F /T
        }
        
        # Make storage and cache directories writable
        if [ -d "$CRM_ROOT/storage" ]; then
            icacls "$CRM_ROOT/storage" /grant:r "$APACHE_USER:(OI)(CI)F" /T
        fi
        if [ -d "$CRM_ROOT/cache" ]; then
            icacls "$CRM_ROOT/cache" /grant:r "$APACHE_USER:(OI)(CI)F" /T
        fi
    else
        echo "⚠️ icacls command not found. Using generic permissions."
        chmod -R 755 "$CRM_ROOT"
    fi
    echo "✅ Permissions set."

    # Create a simple health check
    echo "<?php echo 'CRM Health Check: ' . date('Y-m-d H:i:s'); ?>" > "$CRM_ROOT/public/health.php" || {
        echo "⚠️ Failed to create health check file."
    }
    
    # Restart Apache service
    echo "🔄 Restarting Apache..."
    if command -v httpd &>/dev/null; then
        # Check if Apache is already running
        if netstat -ano | grep -q ":80 "; then
            httpd -k restart || {
                echo "⚠️ Failed to restart Apache. Attempting to stop and start..."
                httpd -k stop
                sleep 2
                httpd -k start || {
                    echo "❌ Failed to start Apache. Please check configuration and try manually."
                    exit 1
                }
            }
        else
            httpd -k start || {
                echo "❌ Failed to start Apache. Please check configuration and try manually."
                exit 1
            }
        fi
    else
        # Try using Windows service name
        net stop Apache2.4 && net start Apache2.4 || {
            echo "⚠️ Failed to restart Apache via service. Please restart it manually."
        }
    fi

    # Final check of services
    echo "🔍 Checking services..."
    if netstat -ano | grep -q ":80 "; then
        echo "✅ Apache is running and listening on port 80."
    else
        echo "⚠️ Apache may not be running on port 80. Please check configuration."
    fi
    
    if netstat -ano | grep -q ":3306 "; then
        echo "✅ MariaDB is running and listening on port 3306."
    else
        echo "⚠️ MariaDB may not be running. Please check configuration."
    fi

    # Firewall configuration
    echo "🔧 Configuring Windows Firewall..."
    # Check if PowerShell is available
    if command -v powershell &>/dev/null; then
        powershell -Command "New-NetFirewallRule -DisplayName 'Allow HTTP' -Direction Inbound -Protocol TCP -LocalPort 80 -Action Allow" || {
            echo "⚠️ Failed to create firewall rule. Please manually allow port 80 in Windows Firewall."
        }
    else
        echo "⚠️ PowerShell not found. Please manually add a firewall rule for port 80."
    fi

    echo "✅ Windows setup completed successfully."
    echo "📝 You can now complete the installation of your CRM from the web browser using: http://$server_ip"
    echo "👉 Health check URL: http://$server_ip/health.php"
    echo "⚠️ SECURITY REMINDER: Run 'mysql_secure_installation' to secure your MariaDB installation."
    echo "📋 Configuration summary:"
    echo "  - Database: CRM"
    echo "  - Database User: $db_user"
    echo "  - Document Root: $CRM_ROOT"
    echo "  - Apache Configuration: $APACHE_CONF"
    echo "  - PHP Configuration: $PHP_INI"
    echo "⚠️ Important: If you encounter issues, check Apache and MariaDB logs."
    echo "    - Apache logs: $APACHE_PATH/logs/"
    echo "    - MariaDB logs: Check Windows Event Viewer"
fi