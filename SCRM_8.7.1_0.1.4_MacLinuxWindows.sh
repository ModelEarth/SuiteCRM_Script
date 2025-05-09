#!/bin/bash

# Function to request user input
get_input() {
    read -p "$1: " value
    echo $value
}

# Safe wrapper for Homebrew commands — skips if running as root
brew_safe() {
  if [[ "$EUID" -eq 0 ]]; then
    echo "⚠️ Skipping: brew $* (Homebrew cannot run as root)"
  else
    brew "$@"
  fi
}
#!/bin/bash

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

# Request user information
echo ""
echo "Choose where to set up your SuiteCRM database:"
echo "1 - Azure (remotely)"
echo "2 - MariaDB (locally)"
read -p "Enter your choice [1/2]: " db_choice

if [[ "$db_choice" == "1" ]]; then
    echo "🧭 Azure setup selected."

    # Prompt for Azure DB inputs, place holder
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

      # $PATH is inherited from the environment of the shell running the script.

      # script modifies the runtime value of $PATH immediately and also persists the change for future sessions by appending to ~/.zprofile.
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

    # Install PECL and common PHP extensions
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
    
    # Removed sudo/root check to allow macOS install with sudo if needed
    #if [[ "$EUID" -eq 0 ]]; then
      #echo "❌ Do not run this script as root or with sudo on macOS."
      #echo "The script will prompt for password when needed using 'sudo'."
      #exit 1
    #fi

    # Check for Homebrew installation
    echo "🔍 Checking for Homebrew..."
    if ! command -v brew &> /dev/null; then
      echo "🍺 Homebrew not found. Installing..."
      /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" || {
        echo "❌ Failed to install Homebrew. Please install it manually: https://brew.sh"
        exit 1
      }
      
      # Add Homebrew to PATH if not already there
      if [[ "$(uname -m)" == "arm64" ]]; then
        # For Apple Silicon
        echo 'eval "$(/opt/homebrew/bin/brew shellenv)"' >> ~/.zprofile
        eval "$(/opt/homebrew/bin/brew shellenv)"
      else
        # For Intel Macs
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
    echo "🔄 Updating Homebrew and packages..."
    brew_safe update && brew_safe upgrade || {
      echo "⚠️ Warning: Failed to update Homebrew. Continuing anyway..."
    }

    # Install essential packages
    install_package wget || exit 1
    install_package unzip || exit 1

    # Install PHP 8.2 if not already installed or update if needed
    CURRENT_PHP=""
    if command -v php >/dev/null 2>&1; then
      CURRENT_PHP="$(php -v | head -n 1 | awk '{print $2}')"
    fi
    
    # Check PHP version and install/update if needed
    if [ -n "$CURRENT_PHP" ]; then # PHP already exists
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
        # No PHP installed, so install it
        install_php_macos || {
          echo "❌ Failed to install PHP 8.2"
          exit 1
        }
    fi

    # Install and configure Apache
    echo "🔧 Installing and configuring Apache Server..."
    install_package httpd || exit 1

    # Start Apache service with error handling
    echo "🔧 Starting Apache service..."
    brew_safe services start httpd || {
      echo "⚠️ Failed to start Apache service. Attempting to restart..."
      brew_safe services restart httpd || {
        echo "❌ Failed to start Apache. Please check the Apache configuration."
        exit 1
      }
    }

    # Define Apache and PHP paths
    HTTPD_CONF="/opt/homebrew/etc/httpd/httpd.conf"
    HTTPD_VHOSTS="/opt/homebrew/etc/httpd/extra/httpd-vhosts.conf"
    PHP_CONF="/opt/homebrew/etc/httpd/extra/httpd-php.conf"
    PHP_INI="/opt/homebrew/etc/php/8.2/php.ini"
    
    # Check if paths exist, adjust for Intel Macs if needed
    if [ ! -f "$HTTPD_CONF" ]; then
      # Try Intel Mac paths
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
            # Find PHP module location
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
    fi


    # Define document root and directories
    # Find proper Homebrew document root
    DOCUMENT_ROOT="/opt/homebrew/var/www"
    if [ ! -d "$DOCUMENT_ROOT" ]; then
        # Try Intel Mac path
        DOCUMENT_ROOT="/usr/local/var/www"
        if [ ! -d "$DOCUMENT_ROOT" ]; then
            # Create it if it doesn't exist
            echo "🔧 Creating document root directory..."
            sudo mkdir -p "$DOCUMENT_ROOT"
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
    if [ ! -f "suitecrm-8-7-1.zip" ]; then
        echo "📦 Downloading SuiteCRM..."
        wget https://suitecrm.com/download/148/suite87/564667/suitecrm-8-7-1.zip || {
            echo "❌ Failed to download SuiteCRM."
            exit 1
        }
    else
        echo "✅ SuiteCRM archive already exists, using cached version."
    fi
    
    # Extract SuiteCRM
    echo "📦 Extracting SuiteCRM..."
    unzip -o suitecrm-8-7-1.zip || {
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
        sudo mkdir -p "$VHOSTS_DIR" || {
            echo "❌ Failed to create vhosts directory."
            exit 1
        }
    fi
    
    # Enable vhosts module in main config
    sed -i '' 's/#Include.*httpd-vhosts.conf/Include \/opt\/homebrew\/etc\/httpd\/extra\/httpd-vhosts.conf/g' "$HTTPD_CONF" || {
        echo "⚠️ Failed to enable vhosts in Apache config. Manual configuration may be required."
    }
    
    # Create VirtualHost configuration with security headers
    cat << EOF > "$HTTPD_VHOSTS"
# Default virtual host (respond to any unmatched requests)
<VirtualHost *:8080>
    DocumentRoot "/opt/homebrew/var/www"
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
    
    # Restart services
    echo "🔄 Restarting services..."
    brew_safe services restart httpd || echo "⚠️ Failed to restart Apache"
    brew_safe services restart mariadb || echo "⚠️ Failed to restart MariaDB"
    
    # Create a simple health check
    echo "<?php echo 'CRM Health Check: ' . date('Y-m-d H:i:s'); ?>" > "$CRM_ROOT/public/health.php"
    chmod 644 "$CRM_ROOT/public/health.php" || {
        echo "⚠️ Failed to create health check file."
    }
    
    echo "✅ macOS web setup completed successfully. Database might need additional cmds."
    echo "📝 You can now complete the installation of your CRM at: http://$server_ip:8080"
    echo "👉 Health check URL: http://$server_ip:8080/health.php"
    echo "⚠️ SECURITY REMINDER: Run 'mysql_secure_installation' to secure your MariaDB installation."
    echo "📋 Configuration summary:"
    echo "  - Database: CRM"
    echo "  - Database User: $db_user"
    echo "  - Document Root: $CRM_ROOT"
    echo "  - Apache port: 8080 (Homebrew default)"


    # Install and configure MariaDB
    echo "🔧 Installing MariaDB..."
    install_package mariadb || exit 1

    # Start MariaDB service with error handling
    echo "🔧 Starting MariaDB service..."
    brew_safe services start mariadb || {
      echo "⚠️ Failed to start MariaDB service. Attempting to restart..."
      brew_safe services restart mariadb || {
        echo "❌ Failed to start MariaDB. Please check for errors."
        exit 1
      }
    }

    # Check if MariaDB is running
    if ! pgrep -f "mysql" > /dev/null; then
        echo "❌ MariaDB is not running. Cannot continue with database setup."
        exit 1
    else
        echo "✅ MariaDB is running."
    fi

    # Secure MariaDB installation guidance
    echo "⚠️ SECURITY RECOMMENDATION: Run 'mysql_secure_installation' after this script completes."

    # Configure database with error handling
    echo "🔧 Configuring main database..."
    if ! mysql -u root <<EOF
CREATE DATABASE IF NOT EXISTS CRM CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '$db_user'@'localhost' IDENTIFIED BY '$db_pass';
GRANT ALL PRIVILEGES ON CRM.* TO '$db_user'@'localhost';
FLUSH PRIVILEGES;
EOF
    then
        echo "❌ Failed to configure database. Check MariaDB status and permissions."
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


elif [[ "$os" == "linux" ]]; then

    echo "Platform detected: Linux - Beginning setup process..."
    
    # Check for root privileges
    if [[ "$EUID" -ne 0 ]]; then
        echo "❌ This script requires root privileges for Linux installation."
        echo "Please run with sudo: sudo ./setup.sh"
        exit 1
    fi
    
    # Update package lists and upgrade existing packages
    echo "🔄 Updating system packages..."
    apt update && apt upgrade -y || {
        echo "❌ Failed to update system packages. Check your internet connection and apt sources."
        exit 1
    }

    # Install essential packages first
    echo "📦 Installing essential packages..."
    apt install -y unzip wget software-properties-common curl || {
        echo "❌ Failed to install essential packages."
        exit 1
    }

    # Add PHP repository and update
    echo "📦 Adding PHP repository..."
    add-apt-repository ppa:ondrej/php -y || {
        echo "❌ Failed to add PHP repository."
        exit 1
    }
    apt update

    # Install PHP and extensions
    echo "📦 Installing PHP 8.2 and extensions..."
    apt install -y php8.2 libapache2-mod-php8.2 php8.2-cli php8.2-curl php8.2-common php8.2-intl \
        php8.2-gd php8.2-mbstring php8.2-mysqli php8.2-pdo php8.2-mysql php8.2-xml php8.2-zip \
        php8.2-imap php8.2-ldap php8.2-curl php8.2-soap php8.2-bcmath || {
        echo "❌ Failed to install PHP and extensions."
        exit 1
    }

    # Configure Apache
    echo "🔧 Configuring Apache Server..."
    a2enmod rewrite || {
        echo "⚠️ Failed to enable Apache rewrite module. Check if Apache is installed correctly."
    }
    
    # Create a proper configuration file for disabling directory listing
    echo "🔧 Disabling directory listing globally..."
    cat << EOF > /etc/apache2/conf-available/disable-directory-listing.conf
<Directory /var/www/>
    Options -Indexes +FollowSymLinks
    AllowOverride All
    Require all granted
</Directory>
EOF
    a2enconf disable-directory-listing || {
        echo "⚠️ Failed to enable directory listing configuration."
    }
    
    # Install and configure MariaDB with error handling
    echo "📦 Installing MariaDB..."
    apt install mariadb-server mariadb-client -y || {
        echo "❌ Failed to install MariaDB."
        exit 1
    }

    # Start and enable MariaDB service
    echo "🔧 Starting MariaDB service..."
    systemctl start mariadb || {
        echo "❌ Failed to start MariaDB service."
        exit 1
    }
    systemctl enable mariadb || {
        echo "⚠️ Failed to enable MariaDB service on startup."
    }

    echo "⚠️ NOTE: For security reasons, you should run 'mysql_secure_installation' after this script completes."

    # Check if MariaDB is running before database configuration
    if systemctl is-active --quiet mariadb; then
        echo "✅ MariaDB is running. Proceeding with database configuration."
    else
        echo "❌ MariaDB is not running. Cannot proceed with database configuration."
        exit 1
    fi

    # Configure database with error handling and verification
    echo "🔧 Configuring main database..."
    mysql -u root <<EOF
CREATE DATABASE IF NOT EXISTS CRM CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '$db_user'@'localhost' IDENTIFIED BY '$db_pass';
GRANT ALL PRIVILEGES ON CRM.* TO '$db_user'@'localhost';
FLUSH PRIVILEGES;
EOF

    # Verify database creation with better error handling
    if ! mysql -u root -e "USE CRM"; then
        echo "❌ Failed to create or access database CRM. Please check MySQL root permissions."
        exit 1
    else
        echo "✅ Database CRM created successfully."
    fi

    # Verify user creation more thoroughly
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

    # Create and configure document root for SuiteCRM
    echo "🔧 Creating document root directories..."
    mkdir -p /var/www/html/crm
    
    # Download SuiteCRM with error handling and cache check
    echo "📦 Downloading SuiteCRM..."
    cd /var/www/html/crm
    if [ ! -f "suitecrm-8-7-1.zip" ]; then
        wget -O suitecrm-8-7-1.zip https://suitecrm.com/download/148/suite87/564667/suitecrm-8-7-1.zip || {
            echo "❌ Failed to download SuiteCRM."
            exit 1
        }
    else
        echo "✅ SuiteCRM archive already exists, using cached version."
    fi
    
    # Extract SuiteCRM with error handling
    echo "📦 Extracting SuiteCRM..."
    unzip -o suitecrm-8-7-1.zip || {
        echo "❌ Failed to extract SuiteCRM."
        exit 1
    }
    echo "✅ SuiteCRM extracted successfully."

    # Configure VirtualHost with proper error handling
    echo "🔧 Configuring VirtualHost..."
    cat << EOF > /etc/apache2/sites-available/crm.conf
<VirtualHost *:80>
    ServerAdmin webmaster@localhost
    DocumentRoot /var/www/html/crm/public
    ServerName $server_ip
    
    <Directory /var/www/html/crm/public>
        Options -Indexes +FollowSymLinks +MultiViews
        AllowOverride All
        Require all granted
    </Directory>
    
    ErrorLog \${APACHE_LOG_DIR}/crm-error.log
    CustomLog \${APACHE_LOG_DIR}/crm-access.log combined
    
    # Security headers
    Header always set X-Content-Type-Options "nosniff"
    Header always set X-XSS-Protection "1; mode=block"
    Header always set X-Frame-Options "SAMEORIGIN"
</VirtualHost>
EOF

    # Enable the site and SSL module
    a2ensite crm.conf || {
        echo "⚠️ Failed to enable CRM virtual host."
    }
    a2enmod headers || {
        echo "⚠️ Failed to enable Apache headers module."
    }

    # Configure php.ini
    echo "🔧 Setting php.ini configuration..."
    PHP_INI="/etc/php/8.2/apache2/php.ini"
    if [ -f "$PHP_INI" ]; then
        # Backup original php.ini
        cp "$PHP_INI" "${PHP_INI}.bak"
        
        # Update PHP settings
        sed -i 's/memory_limit = .*/memory_limit = 512M/' "$PHP_INI"
        sed -i 's/upload_max_filesize = .*/upload_max_filesize = 50M/' "$PHP_INI"
        sed -i 's/post_max_size = .*/post_max_size = 50M/' "$PHP_INI"
        sed -i 's/max_execution_time = .*/max_execution_time = 300/' "$PHP_INI"
        # Add additional security settings
        sed -i 's/display_errors = .*/display_errors = Off/' "$PHP_INI"
        sed -i 's/expose_php = .*/expose_php = Off/' "$PHP_INI"
        
        echo "✅ PHP configuration updated."
    else
        echo "⚠️ PHP configuration file not found at $PHP_INI"
    fi

    # Adjust permissions with optimal security
    echo "🔧 Setting proper permissions..."
    chown -R www-data:www-data /var/www/html/crm
    find /var/www/html/crm -type d -exec chmod 750 {} \;
    find /var/www/html/crm -type f -exec chmod 640 {} \;
    # Make sure executable files remain executable
    if [ -f "/var/www/html/crm/bin/console" ]; then
        chmod +x /var/www/html/crm/bin/console
    fi
    # Make storage directories writable
    if [ -d "/var/www/html/crm/storage" ]; then
        chmod -R 770 /var/www/html/crm/storage
    fi
    if [ -d "/var/www/html/crm/cache" ]; then
        chmod -R 770 /var/www/html/crm/cache
    fi
    echo "✅ Permissions configured."

    # Restart Apache to apply changes
    echo "🔄 Restarting Apache..."
    systemctl restart apache2 || {
        echo "⚠️ Failed to restart Apache. Please check Apache configuration."
    }
    
    # Set up a firewall if UFW is available
    if command -v ufw &> /dev/null; then
        echo "🔧 Configuring firewall..."
        ufw allow 80/tcp
        ufw allow 443/tcp
        echo "✅ Firewall configured to allow HTTP and HTTPS traffic."
    fi
    
    # Create a simple health check
    echo "<?php echo 'CRM Health Check: ' . date('Y-m-d H:i:s'); ?>" > /var/www/html/crm/public/health.php
    chmod 644 /var/www/html/crm/public/health.php
    
    echo "✅ Linux setup completed successfully."
    echo "📝 You can now complete the installation of your CRM from the web browser using: http://$server_ip"
    echo "👉 Health check URL: http://$server_ip/health.php"
    echo "⚠️ SECURITY REMINDER: Run 'sudo mysql_secure_installation' to secure your MariaDB installation."
    echo "📋 Configuration summary:"
    echo "  - Database: CRM"
    echo "  - Database User: $db_user"
    echo "  - Document Root: /var/www/html/crm"


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
    
    if [ ! -f "suitecrm-8-7-1.zip" ]; then
        wget -O suitecrm-8-7-1.zip https://suitecrm.com/download/148/suite87/564667/suitecrm-8-7-1.zip || {
            echo "❌ Failed to download SuiteCRM."
            exit 1
        }
    else
        echo "✅ SuiteCRM archive already exists, using cached version."
    fi
    
    echo "📦 Extracting SuiteCRM..."
    unzip -o suitecrm-8-7-1.zip || {
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