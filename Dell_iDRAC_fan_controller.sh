#!/bin/bash

# Enable strict bash mode to stop the script if an uninitialized variable is used, if a command fails, or if a command with a pipe fails
# Not working in some setups : https://github.com/tigerblue77/Dell_iDRAC_fan_controller/issues/48
# set -euo pipefail

cd "$(dirname "$0")"

if [[ -f config.properties ]]; then
  source config.properties
fi
source functions.sh
source fan_control.sh
if [[ -f telegraf-integration.sh ]]; then
  source telegraf-integration.sh
fi


# Trap the signals for container exit and run gracefull_exit function
trap 'gracefull_exit' SIGQUIT SIGKILL SIGTERM

# Check if the iDRAC host is set to 'local' or not then set the IDRAC_LOGIN_STRING accordingly
if [[ $IDRAC_HOST == "local" ]]
then
  # Check that the Docker host IPMI device (the iDRAC) has been exposed to the Docker container
  if [ ! -e "/dev/ipmi0" ] && [ ! -e "/dev/ipmi/0" ] && [ ! -e "/dev/ipmidev/0" ]; then
    echo "/!\ Could not open device at /dev/ipmi0 or /dev/ipmi/0 or /dev/ipmidev/0, check that you added the device to your Docker container or stop using local mode. Exiting." >&2
    exit 1
  fi
  IDRAC_LOGIN_STRING='open'
else
  echo "iDRAC/IPMI username: $IDRAC_USERNAME"
  echo "iDRAC/IPMI password: $IDRAC_PASSWORD"
  IDRAC_LOGIN_STRING="lanplus -H $IDRAC_HOST -U $IDRAC_USERNAME -P $IDRAC_PASSWORD"
fi

get_Dell_server_model

if [[ ! $SERVER_MANUFACTURER == "DELL" ]]
then
  echo "/!\ Your server isn't a Dell product. Exiting." >&2
  exit 1
fi

# Log main informations
echo "Server model: $SERVER_MANUFACTURER $SERVER_MODEL"
echo "iDRAC/IPMI host: $IDRAC_HOST"

# Log the check interval
echo "Check interval: ${CHECK_INTERVAL}s"
echo ""

# Start monitoring
last_reset_hddtemps=$(date +%s)
last_reset_ambient_ipmitemps=$last_reset_hddtemps
last_reset_healthcheck=$last_reset_hddtemps
ambient_temp=20

ambient_ipmitemps=()
cputemps=()
coretemps=()
hddtemps=()
while true; do
  debug "Main loop start"
  # Sleep for the specified interval before taking another reading
  sleep $CHECK_INTERVAL &
  SLEEP_PROCESS_PID=$!

  get_ambient_temp "ambient_ipmitemps" "ambient_temp"
  get_cpu_temps "cputemps" "coretemps"
  get_hdd_temps "hddtemps"

  for ((i = 0; i < ${#cputemps[@]}; i++)); do
    cputemps[$i]=${cputemps[$i]%$'\n'}
    cputemps[$i]=$( echo "${cputemps[$i]}" | sed -E 's/.*: *[-+]?([0-9.]+)..?C\b.*/\1/' ) 
  done
  for ((i = 0; i < ${#coretemps[@]}; i++)); do
    coretemps[$i]=${coretemps[$i]%$'\n'}
    coretemps[$i]=$( echo "${coretemps[$i]}" | sed -E 's/.*: *[-+]?([0-9.]+)..?C\b.*/\1/' )
  done
  for ((i = 0; i < ${#ambient_ipmitemps[@]}; i++)); do
    ambient_ipmitemps[$i]=${ambient_ipmitemps[$i]%$'\n'}
    ambient_ipmitemps[$i]=$( echo "${ambient_ipmitemps[$i]}" | sed -E 's/.*\| ([^ ]*) degrees C.*/\1/' )
  done
  for ((i = 0; i < ${#hddtemps[@]}; i++)); do
    hddtemps[$i]=${hddtemps[$i]%$'\n'}
    hddtemps[$i]=$( echo "${hddtemps[$i]}" | sed -E 's/.*: *([-+0-9.]+)..?C\b.*/\1/' )
  done

  debug "Collected and computed data:"
  debug "Ambient temp: $ambient_temp"
  debug "CPU temp: ${cputemps[*]}"
  debug "Core temp: ${coretemps[*]}"
  debug "HDD temp: ${hddtemps[*]}"

  ambient_temp=$( average "${ambient_ipmitemps[@]}" )
  # FIXME: hysteresis
  if [ "$ambient_temp" -gt "$DEFAULT_THRESHOLD" ]; then
    warning "fallback because of high ambient temperature $ambient_temp > $DEFAULT_THRESHOLD"
    if ! set_fans_default; then
      # return for next loop without resetting timers and delta change if that fails
      error "set_fans_default failed, retrying main loop skipping timers reset"
      continue
    fi
  else
    if ! set_fans_servo "$ambient_temp" "cputemps" "coretemps" "hddtemps"; then
      # return for next loop without resetting timers and delta change if that fails
      error "set_fans_servo failed, retrying main loop skipping timers reset"
      continue
    fi
  fi

  # every 20 minutes (enough to establish spin-down), invalidate the
  # cache of the slowly changing hdd temperatures to allow them to be
  # refreshed
  current_timestamp=$(date +%s)
  if ((current_timestamp - last_reset_hddtemps > 1200)); then
      unset hddtemps
      info "resetting hddtemps"
      last_reset_hddtemps=$current_timestamp
  fi
  # every 60 seconds, invalidate the cache of the slowly changing
  # ambient temperatures to allow them to be refreshed
  if ((current_timestamp - last_reset_ambient_ipmitemps > 60)); then
      unset ambient_ipmitemps
      info "resetting ambient_ipmitemps"
      current_mode="reset"; # just in case the RAC has rebooted, it
      # will go back into default control, so
      # make sure we set it appropriately once
      # per minute
      last_reset_ambient_ipmitemps=$current_timestamp
  fi
  if [[ -n "$HEALTHCHECK_INTERVAL" && -n "$HEALTHCHECK_URL" ]]; then
    if ((current_timestamp - last_reset_healthcheck > HEALTHCHECK_INTERVAL)); then
        if curl -fsS --retry 3 "$HEALTHCHECK_URL" >/dev/null 2>&1; then
          debug "Healthcheck called OK"
        else
          error "Healthcheck call FAILED."
        fi
        last_reset_healthcheck=$current_timestamp
    fi
  fi

  wait $SLEEP_PROCESS_PID
done
