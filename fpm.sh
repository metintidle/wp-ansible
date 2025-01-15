#!/bin/sh
#get the numbeŕ of cupu cores
cores=$(nproc)

load=$(awk '{print $1}' </proc/loadavg)
cpuUsage=$(echo | awk -v c="${cores}" -v l="${load}" '{print l*100/c}' | awk -F. '{print $1}')
now=$(date)

if [ $cpuUsage -ge 90 ]; then
  echo "[$now]: $cpuUsage% is using by CPU."
  sudo systemctl restart php-fpm
fi

freeMemory=$(free -m | grep Mem | awk '{print int($4/$2*100)}')
now=$(date)

if [ $freeMemory -lt 10 ]; then

  echo "[$now]: $freeMemory% free Memory"
  sudo systemctl restart php-fpm
fi

# Check if buffer or cache is taking more than 40% of RAM
bufferCacheUsage=$(free -m | awk '/^Mem:/ {print int($6/$2*100)}')
now=$(date)

if [ $bufferCacheUsage -gt 30 ]; then
  sync
  echo 1 >/proc/sys/vm/drop_caches
  echo "[$now]: $bufferCacheUsage% of RAM is used by buffer/cache."
  sudo systemctl restart php-fpm
fi
