#!/bin/bash

# much of this stolen from /etc/munin/plugins/hddtemp_smartctl

for drive in "$@"; do
  sense=$(hdparm -C "$drive" 2>/dev/null)
  if [[ ! $sense =~ "standby" ]]; then
    output=$(smartctl -A -i --nocheck=standby "$drive")
    model=$(echo -e "$output" | sed -n -E 's/(Model Number|Device Model):\s*(.*)/\2/p')
    temp=$(echo -e "$output" | sed -n -E 's/Current\ Drive\ Temperature:\s*(\d+)/\1/p')
    if [[ -z $temp ]]; then
      temp=$(echo -e "$output" | grep -E "^(194 Temperature_(Celsius|Internal).*)" | awk '{print $10}')
    fi
    if [[ -z $temp ]]; then
      temp=$(echo -e "$output" | grep -E "^(231 Temperature_Celsius.*)" | awk '{print $10}')
    fi
    if [[ -z $temp ]]; then
      temp=$(echo -e "$output" | grep -E "^(190 (Airflow_Temperature_Cel|Temperature_Case).*)" | awk '{print $10}')
    fi
    if [[ -z $temp ]]; then
      temp=$(echo -e "$output" | sed -E 's/Temperature:\s*(\d+)\sCelsius/\1/p')
    fi
    if [[ -z $temp ]]; then
      echo "$drive: Smart not available"
    else
      echo "$drive: $model: $temp°C"
    fi
  else
    echo "$drive: Sleeping. Temperature not available"
  fi
done
