#!/bin/bash

# Downgrade PHP to 8.1
sudo systemctl stop php-fpm
sudo yum remove -y php8.4*
sudo yum install -y php8.1 php8.1-fpm php8.1-mysqlnd php8.1-mbstring php8.1-intl php8.1-gd php8.1-zip php8.1-devel php-pear libwebp-tools

# Backup php.ini and www.conf files
sudo cp /etc/php.ini /etc/php.ini.backup
sudo cp /etc/php-fpm.d/www.conf /etc/php-fpm.d/www.conf.backup

# Update PHP-FPM configuration
sudo sed -i 's/^user =.*/user = ec2-user/' /etc/php-fpm.d/www.conf
sudo sed -i 's/^group =.*/group = nginx/' /etc/php-fpm.d/www.conf
sudo sed -i 's/^pm =.*/pm = dynamic/' /etc/php-fpm.d/www.conf
sudo sed -i 's/^pm.max_children =.*/pm.max_children = 3/' /etc/php-fpm.d/www.conf
sudo sed -i 's/^pm.start_servers =.*/pm.start_servers = 1/' /etc/php-fpm.d/www.conf
sudo sed -i 's/^pm.min_spare_servers =.*/pm.min_spare_servers = 1/' /etc/php-fpm.d/www.conf
sudo sed -i 's/^pm.max_spare_servers =.*/pm.max_spare_servers = 2/' /etc/php-fpm.d/www.conf
sudo sed -i 's/^;*pm.max_requests =.*/pm.max_requests = 500/' /etc/php-fpm.d/www.conf

# Update PHP configuration
sudo sed -i 's/^upload_max_filesize =.*/upload_max_filesize = 300M/' /etc/php.ini
sudo sed -i 's/^post_max_size =.*/post_max_size = 300M/' /etc/php.ini
sudo sed -i 's/^max_execution_time =.*/max_execution_time = 300/' /etc/php.ini
sudo sed -i 's/^memory_limit =.*/memory_limit = 96M/' /etc/php.ini
sudo sed -i 's|^;session.save_path = .*|session.save_path = "/tmp"|' /etc/php.ini
echo "realpath_cache_size = 1024k" | sudo tee -a /etc/php.ini
echo "realpath_cache_ttl = 300" | sudo tee -a /etc/php.ini

# Set permissions for wp-content
sudo chmod -R 775 ~/html/wp-content
sudo chown -R ec2-user:nginx ~/html/wp-content

# Restart services
sudo systemctl start php-fpm
sudo systemctl restart nginx

echo "PHP downgraded to 8.1 and configured successfully!"