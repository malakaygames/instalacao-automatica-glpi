#!/bin/bash

# Cores para formatação
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Função para exibir mensagens de progresso
show_progress() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

# Função para resetar completamente o MySQL
reset_mysql() {
    show_progress "Resetando completamente o MySQL..."
    
    # Parar o serviço do MySQL
    systemctl stop mariadb
    
    # Remover arquivos de configuração e dados
    rm -rf /var/lib/mysql/*
    rm -f /etc/mysql/debian.cnf
    
    # Reinstalar o MariaDB
    apt-get remove --purge -y mariadb-server mariadb-client
    apt-get autoremove -y
    apt-get autoclean
    rm -rf /var/lib/mysql
    rm -rf /var/log/mysql
    rm -rf /etc/mysql
    
    # Reinstalar o MariaDB
    apt-get update
    apt-get install -y mariadb-server mariadb-client
    
    # Iniciar o serviço
    systemctl start mariadb
    systemctl enable mariadb
    
    # Aguardar o serviço iniciar completamente
    sleep 5
    
    show_progress "MySQL resetado com sucesso!"
}

# Função para configurar o MySQL
setup_mysql() {
    local MYSQL_ROOT_PASS=$1
    
    show_progress "Configurando MySQL..."
    
    mysql -u root << EOF
ALTER USER 'root'@'localhost' IDENTIFIED BY '$MYSQL_ROOT_PASS';
DELETE FROM mysql.user WHERE User='';
DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');
DROP DATABASE IF EXISTS test;
DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';
FLUSH PRIVILEGES;
EOF
}

# Solicitar entrada do usuário para todas as configurações necessárias
read -p "Digite o nome do usuário comum GLPI: " user_glpi
read -s -p "Digite a senha do usuário GLPI: " pass_glpi
echo
read -p "Digite o nome do usuário do banco GLPI: " user_root
read -s -p "Digite a senha do usuário do banco GLPI: " pass_root
echo
read -s -p "Digite a nova senha do root do MySQL: " mysql_root_pass
echo
read -p "Digite o nome do banco de dados: " db_name

# Atualizar o sistema
show_progress "Atualizando o sistema..."
apt update && apt upgrade -y

# Instalar Apache e PHP primeiro
show_progress "Instalando Apache e PHP..."
apt install -y apache2 libapache2-mod-php \
php-soap php-cas php php-{apcu,cli,common,curl,gd,imap,ldap,mysql,xmlrpc,xml,mbstring,bcmath,intl,zip,redis,bz2}

# Resetar e reinstalar MySQL
reset_mysql

# Configurar MySQL com nova senha
setup_mysql "$mysql_root_pass"

# Instalar outras dependências
show_progress "Instalando outras dependências..."
apt install -y xz-utils bzip2 unzip curl git

# Configurar banco de dados para GLPI
show_progress "Configurando banco de dados..."
mysql -u root -p"${mysql_root_pass}" << EOF
CREATE DATABASE IF NOT EXISTS $db_name CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER '$user_root'@'localhost' IDENTIFIED BY '$pass_root';
GRANT ALL PRIVILEGES ON $db_name.* TO '$user_root'@'localhost' WITH GRANT OPTION;
GRANT SELECT ON mysql.time_zone_name TO '$user_root'@'localhost';
FLUSH PRIVILEGES;
EOF

# Configurar Apache para GLPI
show_progress "Configurando Apache..."
cat << EOF > /etc/apache2/conf-available/glpi.conf
<Directory "/var/www/html/glpi">
    Options FollowSymLinks
    AllowOverride All
    Require all granted
</Directory>
EOF

# Habilitar módulos necessários do Apache
if command -v a2enmod &> /dev/null; then
    a2enmod rewrite
    a2enconf glpi
else
    show_progress "Comandos a2enmod/a2enconf não encontrados. Verifique a instalação do Apache2."
fi

# Configuração do Virtual Host para o GLPI
cat << EOF > /etc/apache2/sites-available/000-default.conf
<VirtualHost *:80>
    ServerAdmin webmaster@localhost
    DocumentRoot /var/www/html
    
    <Directory /var/www/html>
        Options FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>

    ErrorLog \${APACHE_LOG_DIR}/error.log
    CustomLog \${APACHE_LOG_DIR}/access.log combined
</VirtualHost>
EOF

# Criar diretório para o GLPI
show_progress "Baixando e configurando GLPI..."
cd /var/www/html
rm -rf glpi  # Remove instalações anteriores se existirem

# Baixar e descompactar o GLPI
wget https://github.com/glpi-project/glpi/releases/download/10.0.15/glpi-10.0.15.tgz
tar xzf glpi-10.0.15.tgz
rm glpi-10.0.15.tgz

# Ajustar permissões
show_progress "Ajustando permissões..."
chown -R www-data:www-data /var/www/html/glpi
find /var/www/html/glpi -type d -exec chmod 755 {} \;
find /var/www/html/glpi -type f -exec chmod 644 {} \;

# Configuração do PHP
show_progress "Configurando PHP..."
php_version=$(php -r "echo PHP_MAJOR_VERSION.'.'.PHP_MINOR_VERSION;")
php_ini_path="/etc/php/${php_version}/apache2/php.ini"

sed -i 's/^memory_limit.*/memory_limit = 64M/' $php_ini_path
sed -i 's/^upload_max_filesize.*/upload_max_filesize = 2M/' $php_ini_path
sed -i 's/^max_execution_time.*/max_execution_time = 600/' $php_ini_path
sed -i 's/^session.cookie_httponly.*/session.cookie_httponly = on/' $php_ini_path

# Configurar timezone no MySQL
mysql_tzinfo_to_sql /usr/share/zoneinfo | mysql -u root -p"${mysql_root_pass}" mysql

# Reiniciar serviços
show_progress "Reiniciando serviços..."
systemctl restart apache2
systemctl restart mariadb

# Instalar GLPI via CLI
show_progress "Finalizando instalação do GLPI..."
php /var/www/html/glpi/bin/console db:install \
--db-host=localhost \
--db-name=$db_name \
--db-user=$user_root \
--db-password=$pass_root \
--no-interaction \
--force

# Configurar usuário comum do GLPI
php /var/www/html/glpi/bin/console user:create \
--login=$user_glpi \
--password=$pass_glpi \
--super-admin \
--no-interaction

# Ajustar permissões finais
chown -R www-data:www-data /var/www/html/glpi/files
chown -R www-data:www-data /var/www/html/glpi/config

# Exibir informações para o usuário
ip_address=$(hostname -I | awk '{print $1}')

echo -e "\n${BLUE}+-------------------------------------------------------------+${NC}"
echo -e "${BLUE}|                  ${YELLOW}Instalação Completa!                      ${BLUE}|${NC}"
echo -e "${BLUE}+-------------------------------------------------------------+${NC}"
echo -e "${BLUE}| ${YELLOW}Acesso ao GLPI:${NC} http://$ip_address/glpi                     ${BLUE}|${NC}"
echo -e "${BLUE}+-------------------------------------------------------------+${NC}"
echo -e "${BLUE}| ${YELLOW}Diretório de instalação:${NC} /var/www/html/glpi              ${BLUE}|${NC}"
echo -e "${BLUE}+-------------------------------------------------------------+${NC}"
echo -e "${BLUE}| ${YELLOW}Usuário comum GLPI:${NC} $user_glpi                            ${BLUE}|${NC}"
echo -e "${BLUE}| ${YELLOW}Senha do usuário:${NC} $pass_glpi                              ${BLUE}|${NC}"
echo -e "${BLUE}+-------------------------------------------------------------+${NC}"
echo -e "${BLUE}| ${YELLOW}Dados do Banco de Dados                                    ${BLUE}|${NC}"
echo -e "${BLUE}+-------------------------------------------------------------+${NC}"
echo -e "${BLUE}| ${YELLOW}Nome do Banco:${NC} $db_name                                    ${BLUE}|${NC}"
echo -e "${BLUE}| ${YELLOW}Usuário do Banco:${NC} $user_root                              ${BLUE}|${NC}"
echo -e "${BLUE}| ${YELLOW}Senha do Banco:${NC} $pass_root                                ${BLUE}|${NC}"
echo -e "${BLUE}+-------------------------------------------------------------+${NC}"

show_progress "Instalação concluída! Você já pode acessar o GLPI pelo navegador."
