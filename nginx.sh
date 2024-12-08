#!/bin/bash

# Update the package index
sudo yum update -y

# Install necessary packages
sudo amazon-linux-extras install nginx1 -y
sudo amazon-linux-extras enable php8.2
sudo yum install -y php-fpm php-mysqlnd php-mbstring php-intl
