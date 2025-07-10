#!/bin/bash

SERVICE="php-fpm"
SOCKET="/run/php-fpm/www.sock"
MAX_LOAD=1.5   # Adjust based on your CPU core count (1.0 = 100% of 1 core)
MAX_MEM_MB=450 # Restart if memory used exceeds this (leave headroom)
WAIT_BEFORE_RESTART=30
LOG_FILE="/var/log/fpm-monitor.log"

timestamp() {
  date +"%Y-%m-%d %H:%M:%S"
}

# Get current system load (1 min average)
CURRENT_LOAD=$(awk '{print $1}' /proc/loadavg)

# Get memory used in MB
USED_MEM_MB=$(free -m | awk '/Mem:/ {print $3}')

# Check if load or memory is too high
if (($(echo "$CURRENT_LOAD > $MAX_LOAD" | bc -l))) || [ "$USED_MEM_MB" -gt "$MAX_MEM_MB" ]; then
  echo "$(timestamp) - High load or memory: load=$CURRENT_LOAD, mem=${USED_MEM_MB}MB. Waiting $WAIT_BEFORE_RESTART sec..." >"$LOG_FILE"

  sleep $WAIT_BEFORE_RESTART

  # Re-check memory and load
  CURRENT_LOAD=$(awk '{print $1}' /proc/loadavg)
  USED_MEM_MB=$(free -m | awk '/Mem:/ {print $3}')

  if (($(echo "$CURRENT_LOAD > $MAX_LOAD" | bc -l))) || [ "$USED_MEM_MB" -gt "$MAX_MEM_MB" ]; then
    echo "$(timestamp) - Restarting $SERVICE: load=$CURRENT_LOAD, mem=${USED_MEM_MB}MB." >"$LOG_FILE"
    systemctl restart "$SERVICE"
  else
    echo "$(timestamp) - Resources normalized after wait. No restart needed." >"$LOG_FILE"
  fi
else
  echo "$(timestamp) - System healthy: load=$CURRENT_LOAD, mem=${USED_MEM_MB}MB." >"$LOG_FILE"
fi
