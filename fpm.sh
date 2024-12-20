#!/bin/sh
#get the numbeŕ of cupu cores
cores=$(nproc)

load=$(awk '{print $1}' </proc/loadavg)
cpuUsage=$(echo | awk -v c="${cores}" -v l="${load}" '{print l*100/c}' | awk -F. '{print $1}')
now=$(date)
echo "[$now]: $cpuUsage% is using by CPU."

if [ $cpuUsage -ge 90 ]; then
  sudo systemctl restart php-fpm
fi

freeMemory=$(free -m | grep Mem | awk '{print int($4/$2*100)}')
now=$(date)
echo "[$now]: $freeMemory% free Memory"

if [ $freeMemory -lt 20 ]; then
  sudo systemctl restart php-fpm
fi
