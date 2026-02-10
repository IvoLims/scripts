#!/usr/bin/env bash
set -euo pipefail

JOB_FILE="$HOME/Scripts/.server_manager_jobs.json"

SUNSHINE_SERVICE="sunshine.service"
TAILSCALE_SERVICE="tailscaled.service"

# Ensure jq is installed
if ! command -v jq >/dev/null 2>&1; then
  echo "Error: jq is required but not installed. Please install jq:"
  echo "sudo pacman -S jq"
  exit 1
fi

# Load jobs JSON array or empty array
load_jobs() {
  if [[ -f "$JOB_FILE" ]]; then
    jq '.' "$JOB_FILE" 2>/dev/null || echo "[]"
  else
    echo "[]"
  fi
}

# Save jobs JSON array to file
save_jobs() {
  local jobs_json="$1"
  echo "$jobs_json" > "$JOB_FILE"
}

# Clear all jobs from JSON file
clean_jobs_json() {
  echo "[]" > "$JOB_FILE"
}

# Add or replace job (max one per type)
add_job_json() {
  local target="$1"
  local unit="$2"
  local time="$3"
  local type="$4"

  local jobs
  jobs=$(load_jobs)

  # Remove existing jobs of same type
  jobs=$(echo "$jobs" | jq --arg type "$type" '[.[] | select(.type != $type)]')

  # Add new job
  jobs=$(echo "$jobs" | jq --arg target "$target" --arg unit "$unit" --arg time "$time" --arg type "$type" \
    '. + [{"target": $target, "unit": $unit, "time": $time, "type": $type}]')

  # Keep max last 2 jobs (for safety)
  jobs=$(echo "$jobs" | jq '.[-2:]')

  save_jobs "$jobs"
}

# List scheduled jobs nicely
list_jobs_json() {
  local jobs
  jobs=$(load_jobs)
  local length
  length=$(echo "$jobs" | jq length)
  if (( length == 0 )); then
    echo "No scheduled jobs."
    return
  fi
  echo "Scheduled jobs:"
  for i in $(seq 0 $((length-1))); do
    local job
    job=$(echo "$jobs" | jq ".[$i]")
    local target=$(echo "$job" | jq -r '.target')
    local unit=$(echo "$job" | jq -r '.unit')
    local time=$(echo "$job" | jq -r '.time')
    local type=$(echo "$job" | jq -r '.type')
    echo "$((i+1))) Target: $target | Unit: $unit | Time: $time | Type: $type"
  done
}

# Cancel job by number
cancel_job_json() {
  local jobs
  jobs=$(load_jobs)
  local length
  length=$(echo "$jobs" | jq length)
  if (( length == 0 )); then
    echo "No scheduled jobs to cancel."
    return
  fi

  list_jobs_json
  echo
  echo -n "Enter job number to cancel (or empty to abort): "
  read -r num
  if [[ -z $num ]]; then
    echo "Cancel aborted."
    return
  fi
  if ! [[ $num =~ ^[0-9]+$ ]] || (( num < 1 || num > length )); then
    echo "Invalid number."
    return
  fi

  local job unit
  job=$(echo "$jobs" | jq ".[$((num-1))]")
  unit=$(echo "$job" | jq -r '.unit')

  echo "Stopping and disabling systemd unit $unit ..."
  sudo systemctl stop "$unit" 2>/dev/null || true
  sudo systemctl disable "$unit" 2>/dev/null || true
  sudo systemctl reset-failed "$unit" 2>/dev/null || true

  jobs=$(echo "$jobs" | jq "del(.[$((num-1))])")
  save_jobs "$jobs"
  echo "Job $num canceled."
}

# Parse time string to systemd time format and delay in seconds
# Supports absolute (HH:MM) and relative (e.g. 30m, 1h30m)
# Returns two globals:
#   schedule_time_str - systemd time string or empty if error
#   delay_seconds - delay in seconds or 0 if error
parse_time() {
  local input="$1"
  schedule_time_str=""
  delay_seconds=0

  # Absolute time HH:MM, 24h format
  if [[ "$input" =~ ^([01]?[0-9]|2[0-3]):([0-5][0-9])$ ]]; then
    local hour="${BASH_REMATCH[1]}"
    local minute="${BASH_REMATCH[2]}"
    # Calculate seconds from now to that time
    local now_epoch=$(date +%s)
    local target_epoch=$(date -d "today $hour:$minute" +%s)
    if (( target_epoch <= now_epoch )); then
      # If time passed today, schedule for tomorrow
      target_epoch=$((target_epoch + 86400))
    fi
    delay_seconds=$((target_epoch - now_epoch))
    schedule_time_str="${delay_seconds}s"
    return 0
  fi

  # Relative time like 30m, 1h30m, 2h, 45m
  # Parse with regex groups
  if [[ "$input" =~ ^(([0-9]+)h)?(([0-9]+)m)?$ ]]; then
    local hours="${BASH_REMATCH[2]}"
    local mins="${BASH_REMATCH[4]}"
    ((hours=hours==""?0:hours))
    ((mins=mins==""?0:mins))
    delay_seconds=$((hours*3600 + mins*60))
    if (( delay_seconds == 0 )); then
      echo "Invalid time: $input"
      schedule_time_str=""
      delay_seconds=0
      return 1
    fi
    schedule_time_str="${delay_seconds}s"
    return 0
  fi

  echo "Invalid time format: $input"
  schedule_time_str=""
  delay_seconds=0
  return 1
}

# Start service and enable it
start_service() {
  local service="$1"
  echo "Starting and enabling $service ..."
  sudo systemctl enable --now "$service"
}

# Stop service and disable it
stop_service() {
  local service="$1"
  echo "Stopping and disabling $service ..."
  sudo systemctl stop "$service"
  sudo systemctl disable "$service"
}

# Schedule service stop with systemd-run
schedule_service_stop() {
  local service="$1"
  local time_input="$2"

  parse_time "$time_input" || return 1

  local timestamp
  timestamp=$(date +%s)
  local unit="stop-${service}-${timestamp}.service"

  echo "Scheduling stop of $service in $delay_seconds seconds (at $time_input)..."
  clean_jobs_json
  sudo systemd-run --unit="$unit" --on-active=$schedule_time_str --description="Stop $service service" bash -c "sudo systemctl stop $service && sudo systemctl disable $service"
  add_job_json "$service" "$unit" "$time_input" "service-stop"
  echo "Job saved."
}

# Schedule PC shutdown with systemd-run
schedule_pc_shutdown() {
  local time_input="$1"

  parse_time "$time_input" || return 1

  local timestamp
  timestamp=$(date +%s)
  local unit="shutdown-pc-${timestamp}.service"

  echo "Scheduling PC shutdown in $delay_seconds seconds (at $time_input)..."
  clean_jobs_json
  sudo systemd-run --unit="$unit" --on-active=$schedule_time_str --description="Shutdown PC" bash -c "sudo systemctl poweroff"
  add_job_json "pc" "$unit" "$time_input" "pc-shutdown"
  echo "Job saved."
}

# Info/help screen
show_info() {
  cat << EOF
Server Manager Script - CachyOS

Commands:

1) Start Sunshine server
2) Stop Sunshine server
3) Start Tailscale server
4) Stop Tailscale server
5) Start both servers
6) Stop both servers

7) Schedule Sunshine server stop at time
8) Schedule Tailscale server stop at time
9) Schedule PC shutdown at time

10) List scheduled jobs
11) Cancel scheduled job

12) Exit

Time format for scheduling:
- Relative: 30m, 1h, 1h30m, 2h45m
- Absolute: HH:MM (24h format), e.g. 23:40

Notes:
- Jobs are saved persistently and survive script exit.
- You can schedule service stops or PC shutdown separately.
- Scheduling a new job replaces the previous job of the same type.
- You can cancel jobs before they trigger.
- PC shutdown will power off your machine at the scheduled time.
EOF
}

# Main menu loop
while true; do
  echo
  echo "===== CachyOS Server Manager ====="
  echo "1) Start Sunshine server"
  echo "2) Stop Sunshine server"
  echo "3) Start Tailscale server"
  echo "4) Stop Tailscale server"
  echo "5) Start both servers"
  echo "6) Stop both servers"
  echo "7) Schedule Sunshine server stop"
  echo "8) Schedule Tailscale server stop"
  echo "9) Schedule PC shutdown"
  echo "10) List scheduled jobs"
  echo "11) Cancel scheduled job"
  echo "12) Info / Help"
  echo "13) Exit"
  echo -n "Choose an option: "
  read -r option
  echo

  case "$option" in
    1) start_service "$SUNSHINE_SERVICE" ;;
    2) stop_service "$SUNSHINE_SERVICE" ;;
    3) start_service "$TAILSCALE_SERVICE" && sudo tailscale up ;;
    4) stop_service "$TAILSCALE_SERVICE" ;;
    5)
       start_service "$SUNSHINE_SERVICE"
       start_service "$TAILSCALE_SERVICE"
       sudo tailscale up
       ;;
    6)
       stop_service "$SUNSHINE_SERVICE"
       stop_service "$TAILSCALE_SERVICE"
       ;;
    7)
       echo -n "Enter time to stop Sunshine (e.g. 30m, 1h30m, 23:40): "
       read -r t
       schedule_service_stop "$SUNSHINE_SERVICE" "$t" || echo "Failed to schedule."
       ;;
    8)
       echo -n "Enter time to stop Tailscale (e.g. 30m, 1h30m, 23:40): "
       read -r t
       schedule_service_stop "$TAILSCALE_SERVICE" "$t" || echo "Failed to schedule."
       ;;
    9)
       echo -n "Enter time to shutdown PC (e.g. 30m, 1h30m, 23:40): "
       read -r t
       schedule_pc_shutdown "$t" || echo "Failed to schedule."
       ;;
    10) list_jobs_json ;;
    11) cancel_job_json ;;
    12) show_info ;;
    13) echo "Bye!"; exit 0 ;;
    *) echo "Invalid option." ;;
  esac
done