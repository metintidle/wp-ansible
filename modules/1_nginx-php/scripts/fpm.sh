#!/bin/bash

SERVICE="php-fpm"
SOCKET="/run/php-fpm/www.sock"
MAX_LOAD=1.5        # Adjust based on your CPU core count (1.0 = 100% of 1 core)
MEM_THRESHOLD_PCT=95 # Restart if memory used exceeds this % of total RAM (leave headroom)
WAIT_BEFORE_RESTART=30
LOG_FILE="/var/log/fpm-monitor.log"

timestamp() {
  date +"%Y-%m-%d %H:%M:%S"
}

# Legitimate heavy jobs. Restarting PHP-FPM while one of these is running drops
# in-flight requests without freeing the memory the job is actually holding.
MAINTENANCE_PATTERN='wp-cli|/usr/local/bin/wp |certbot|mysqldump|ansible|backupdb\.sh|(dnf|yum) (install|update|upgrade)'

maintenance_running() {
  pgrep -f "$MAINTENANCE_PATTERN" >/dev/null 2>&1
}

# Ensure service is running; if stopped, start it and verify
if ! systemctl is-active --quiet "$SERVICE"; then
  echo "$(timestamp) - $SERVICE is not active. Attempting to start." >>"$LOG_FILE"
  systemctl start "$SERVICE"
  sleep 2
  if systemctl is-active --quiet "$SERVICE"; then
    echo "$(timestamp) - $SERVICE started successfully." >>"$LOG_FILE"
  else
    echo "$(timestamp) - Failed to start $SERVICE; attempting restart." >>"$LOG_FILE"
    systemctl restart "$SERVICE"
    sleep 2
    if systemctl is-active --quiet "$SERVICE"; then
      echo "$(timestamp) - $SERVICE restarted successfully." >>"$LOG_FILE"
    else
      echo "$(timestamp) - ERROR: $SERVICE still not active after restart." >>"$LOG_FILE"
    fi
  fi
fi

# Get current system load (1 min average)
CURRENT_LOAD=$(awk '{print $1}' /proc/loadavg)

# Get total/used memory in MB, and derive the restart threshold as a % of
# total RAM so the same script works unmodified on 512MB, 1GB, or larger hosts.
TOTAL_MEM_MB=$(free -m | awk '/Mem:/ {print $2}')
MAX_MEM_MB=$((TOTAL_MEM_MB * MEM_THRESHOLD_PCT / 100))
USED_MEM_MB=$(free -m | awk '/Mem:/ {print $3}')

# Check if load or memory is too high
if (($(echo "$CURRENT_LOAD > $MAX_LOAD" | bc -l))) || [ "$USED_MEM_MB" -gt "$MAX_MEM_MB" ]; then
  if maintenance_running; then
    echo "$(timestamp) - High load/mem but a maintenance job is running; skipping." >>"$LOG_FILE"
    exit 0
  fi

  echo "$(timestamp) - High load or memory: load=$CURRENT_LOAD, mem=${USED_MEM_MB}MB. Waiting $WAIT_BEFORE_RESTART sec..." >>"$LOG_FILE"

  sleep $WAIT_BEFORE_RESTART

  # Re-check memory and load
  CURRENT_LOAD=$(awk '{print $1}' /proc/loadavg)
  USED_MEM_MB=$(free -m | awk '/Mem:/ {print $3}')

  if (($(echo "$CURRENT_LOAD > $MAX_LOAD" | bc -l))) || [ "$USED_MEM_MB" -gt "$MAX_MEM_MB" ]; then
    # A job may have started during the wait; re-check before acting.
    if maintenance_running; then
      echo "$(timestamp) - Sustained high load/mem but a maintenance job is running; skipping." >>"$LOG_FILE"
      exit 0
    fi

    # Graceful first: reload (USR2) lets workers finish their current request,
    # so visitors are not dropped. Escalate to restart only if that is not enough.
    echo "$(timestamp) - Reloading $SERVICE: load=$CURRENT_LOAD, mem=${USED_MEM_MB}MB." >>"$LOG_FILE"
    if systemctl reload "$SERVICE"; then
      sleep 5
      USED_MEM_MB=$(free -m | awk '/Mem:/ {print $3}')
      if [ "$USED_MEM_MB" -gt "$MAX_MEM_MB" ]; then
        echo "$(timestamp) - Reload insufficient (mem=${USED_MEM_MB}MB); escalating to restart." >>"$LOG_FILE"
        systemctl restart "$SERVICE"
      else
        echo "$(timestamp) - Reload recovered resources (mem=${USED_MEM_MB}MB); no restart needed." >>"$LOG_FILE"
      fi
    else
      echo "$(timestamp) - Reload failed; escalating to restart." >>"$LOG_FILE"
      systemctl restart "$SERVICE"
    fi
  else
    echo "$(timestamp) - Resources normalized after wait. No restart needed." >>"$LOG_FILE"
  fi
else
  echo "$(timestamp) - System healthy: load=$CURRENT_LOAD, mem=${USED_MEM_MB}MB." >>"$LOG_FILE"
fi
