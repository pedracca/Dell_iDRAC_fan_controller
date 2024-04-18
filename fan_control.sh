#!/bin/bash

function average() {
  local array_param=("$@")

  # Check if the array is empty
  if [ ${#} -eq 0 ]; then
      error "Array is empty"
      return 1
  fi

  local sum=0
  local count=0

  # Loop through each element in the array
  for num in "${@}"; do
    # Check if the element is a number
    if [[ ! $num =~ ^[0-9]+([.][0-9]+)?$ ]]; then
        error "'$num' is not a valid number"
        return 1
    fi
    sum=$( bc <<< "$sum + $num" )
    ((count++))
  done

  # Calculate the average
  local average=$(bc <<< "scale=2; $sum / $count")
  debug "average (${*})=$average"
  printf "%.0f" "$average"
}


function max() {
  # Check if the array is empty
  if [ ${#} -eq 0 ]; then
      error "Array is empty"
      return 1
  fi

  local max=${1}

  # Loop through each element in the array
  for num in "${@}"; do
      # Check if the element is a number
      if [[ ! $num =~ ^[-+]?[0-9]+([.][0-9]+)?$ ]]; then
          error "'$num' is not a valid number"
          return 1
      fi
      # Update max if the current number is greater
      if (( $(bc <<< "$num > $max") )); then
          max=$num
      fi
  done

  echo "$max"
}

function set_fans_servo() {
  local _ambient_temp=$1
  local -n _cputemps="$2"
  local -n _coretemps="$3"
  local -n _hddtemps="$4"

  debug "set_fans_servo(): data in use:"
  debug "set_fans_servo(): Ambient temp: $_ambient_temp"
  debug "set_fans_servo(): CPU temp: ${_cputemps[*]}"
  debug "set_fans_servo(): Core temp: ${_coretemps[*]}"
  debug "set_fans_servo(): HDD temp: ${_hddtemps[*]}"

  # two thirds weighted CPU temps vs hdd temps, but if the HDD temps
  # creep above this value, use them exclusively (more important to
  # keep them cool than the CPUs)

  local average_hddtemps=0
  average_hddtemps=$( average "${_hddtemps[@]}" )
  local average_cputemps=0
  average_cputemps=$( average "${_cputemps[@]}" )
  local average_coretemps=0
  average_coretemps=$( average "${_coretemps[@]}" )

  local weighted_temp=0
  weighted_temp=$( average "$average_cputemps" "$average_coretemps" "$average_hddtemps" )
  weighted_temp=$( max "$weighted_temp" "$average_hddtemps" )
  info "set_fans_servo(): weighted_temp=$weighted_temp"

  if [[ -z "$weighted_temp" || $weighted_temp -eq 0 ]]; then
    error "set_fans_servo(): Error reading all temperatures! Fallback to idrac control"
    #panic
    exit 1
  fi
  if [[ -z "$current_mode" || "$current_mode" != "set" ]]; then
    current_mode="set"
    info "set_fans_servo(): Disabling dynamic fan control"
    if ! call_ipmi "raw 0x30 0x30 0x01 0x00" "quiet"; then
      # if this fails, want to return telling caller not to think weve made a change
      error "set_fans_servo(): Disable dynamic fan control IPMI command failed"
      return 1
    fi
  fi

  # FIXME: probably want to take into account ambient temperature - if
  # the difference between weighted_temp and ambient_temp is small
  # because ambient_temp is large, then less need to run the fans
  # because there's still low power demands
  local demand=0 # want demand to be a reading from 0-100% of
                  # $STATIC_SPEED_LOW - $STATIC_SPEED_HIGH
  if ((weighted_temp > BASE_TEMP && weighted_temp < DESIRED_TEMP1)); then
    # slope m = (y2-y1)/(x2-x1)
    # y - y1 = (x-x1)(y2-y1)/(x2-x1)
    # y1 = 0 ; x1 = BASE_TEMP ; y2 = DEMAND1 ; x2 = DESIRED_TEMP1
    # x = weighted_temp
    debug "set_fans_servo(): using min slope"
    demand=$(( ($weighted_temp - $BASE_TEMP) * $DEMAND1 / ($DESIRED_TEMP1 - $BASE_TEMP) ))
  elif ((weighted_temp >= DESIRED_TEMP2)); then
    # y1 = DEMAND2 ; x1 = DESIRED_TEMP2 ; y2 = DEMAND3 ; x2 = DESIRED_TEMP3
    warning "set_fans_servo(): using max slope"
    demand=$(( $DEMAND2 + ($weighted_temp - $DESIRED_TEMP2) * ($DEMAND3 - $DEMAND2) / ($DESIRED_TEMP3 - $DESIRED_TEMP2) ))
  elif ((weighted_temp >= DESIRED_TEMP1)); then
    # y1 = DEMAND1 ; x1 = DESIRED_TEMP1 ; y2 = DEMAND2 ; x2 = DESIRED_TEMP2
    debug "set_fans_servo(): using med slope"
    demand=$(( $DEMAND1 + ($weighted_temp - $DESIRED_TEMP1) * ($DEMAND2 - $DEMAND1) / ($DESIRED_TEMP2 - $DESIRED_TEMP1) ))
  else
    error "set_fans_servo(): NO SLOPE"
  fi
  debug "set_fans_servo(): computed demand: $demand"
  demand=$(printf "%.0f" $(echo "scale=2; ($STATIC_SPEED_LOW + ($demand / 100) * ($STATIC_SPEED_HIGH - $STATIC_SPEED_LOW))" | bc))
  info "set_fans_servo(): resolved demand: $demand"
  if [ "$demand" -gt 100 ]; then
    demand=100;
    info "set_fans_servo(): capped demand: $demand"
  fi

  if [ -n "$(type -t write_to_telegraf)" ] && [ "$(type -t write_to_telegraf)" = function ]; then
      # La función está definida y existe
      write_to_telegraf "$_ambient_temp" "$average_cputemps" "$average_coretemps" "$average_hddtemps" "$weighted_temp" "$demand"
  fi

  # # ramp down the fans quickly upon lack of demand, don't ramp them up
  # # to tiny spikes of 1 fan unit.  FIXME: But should implement long
  # # term smoothing of +/- 1 fan unit
  if [[ -z "$lastfan" || "$demand" -lt "$lastfan" || "$demand" -gt "$lastfan"+"$HYSTERESIS" ]]; then
    lastfan=$demand
    demand=$( printf "0x%x" "$demand" )
    if ! call_ipmi "raw 0x30 0x30 0x02 0xff $demand"; then
      # if this fails, want to return telling caller not to think wevemade a change
      error "set_fans_servo(): fan demand setting IPMI command failed"
      return 1
    fi
  else
    debug "set_fans_servo(): no changes needed, skipping"
  fi
  return 0
}

function set_fans_default () {
  if [ -z "$current_mode" ] || [ "$current_mode" != "default" ]; then
    current_mode="default"
    unset lastfan
    info "set_fans_default(): lastfan resetted, enabling dynamic fan control"
    for ((attempt=1; attempt<=10; attempt++))
    do
      if call_ipmi "raw 0x30 0x30 0x01 0x01"; then
        info "set_fans_default(): dynamic fan control set successfully"
        return 0
      fi
      sleep 1
      warning "set_fans_default(): Retrying dynamic control $attempt"
    done
    error "set_fans_default(): Retries of dynamic control all failed"
    return 1
  fi
  info "set_fans_default(): already in default mode"
  return 0
}
