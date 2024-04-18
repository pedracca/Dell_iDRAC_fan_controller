#!/bin/bash

function get_hdd_temps() {
  local -n _hddtemps="$1"
  if [[ "${_hddtemps[@]+"set"}" != "set" ]]; then
    debug "hddtemps is empty, collecting new data"
    if [[ -n "$TEST_MODE" ]]; then
      debug "Applying test data to HDD TEMPS"
      mapfile -t _hddtemps < "hddtemps.out"
    else
      debug "Collecting HDD TEMP real data"
      hddtempcmd="timeout -k 1 20 ./hddtemp.sh /dev/sd?" # /dev/nvme?n?" skip errors if no nvme installed
      $hddtempcmd | grep -v 'not available' > $TEMP_FILENAME
      mapfile -t _hddtemps < "$TEMP_FILENAME"
    fi
    # filter in numbers only and remove all extraneous output, and some
    # devices permanently return a *temperature* of 255, so filter them
    # out too.
    mapfile -t _hddtemps < <(printf "%s\n" "${_hddtemps[@]}" | grep -E '[0-9]' | grep -v '255')
    for temp in "${_hddtemps[@]}"; do
      debug "Collected HDD temp data: $temp"
    done
  else
    debug "hddtemps still holds data, skipping new collection"
  fi
}

function get_ambient_temp() {
  local -n _ambient_ipmitemps="$1"
  local -n _ambient_temp="$2"
  if [[ "${_ambient_ipmitemps[@]+"set"}" != "set" ]]; then
    debug "ambient_ipmitemps is empty, collecting new data"
    if [[ -n "$TEST_MODE" ]]; then
      debug "Applying test data to AMBIENT TEMPS"
      #mapfile -t _ambient_ipmitemps < "sdr-temp.out"
      mapfile -t _ambient_ipmitemps < <(grep "$IPMI_INLET_SENSORNAME" "sdr-temp.out" | grep '[0-9]' || echo " | $_ambient_temp degrees C")
    else
      debug "Collecting AMBIENT TEMP real data"
      # ipmitool often fails - just keep using the previous result til it succeeds
      _ambient_ipmitemps=$(timeout -k 1 20 ipmitool sdr type temperature | grep "$IPMI_INLET_SENSORNAME" | grep '[0-9]' || echo " | $_ambient_temp degrees C")
    fi
    debug "Ambient temps: ${_ambient_ipmitemps[*]}"
  else
    debug "ambient_ipmitemps still holds data, skipping new collection"
  fi
}

function get_cpu_temps() {
  local -n _cputemps="$1"
  local -n _coretemps="$2"
  if [[ -n "$TEST_MODE" ]]; then
    debug "Applying test data to CPU and CORE TEMPS"
    mapfile -t _coretemps < "sensors.out"
  else
    _coretemps=$(timeout -k 1 20 sensors | grep '[0-9]')
  fi
  mapfile -t _cputemps < <(printf "%s\n" "${_coretemps[@]}" | grep '^Package id')
  debug "CPU temps: ${_cputemps[*]}"
  mapfile -t _coretemps < <(printf "%s\n" "${_coretemps[@]}" | grep '^Core')
  debug "Core temps: ${_coretemps[*]}"
}

function enable_third_party_PCIe_card_Dell_default_cooling_response() {
  # We could check the current cooling response before applying but it's not very useful so let's skip the test and apply directly
  #ipmitool -I $IDRAC_LOGIN_STRING raw 0x30 0xce 0x00 0x16 0x05 0x00 0x00 0x00 0x05 0x00 0x00 0x00 0x00 > /dev/null
  call_ipmi "raw 0x30 0xce 0x00 0x16 0x05 0x00 0x00 0x00 0x05 0x00 0x00 0x00 0x00" "quiet"
}

function disable_third_party_PCIe_card_Dell_default_cooling_response() {
  # We could check the current cooling response before applying but it's not very useful so let's skip the test and apply directly
  #ipmitool -I $IDRAC_LOGIN_STRING raw 0x30 0xce 0x00 0x16 0x05 0x00 0x00 0x00 0x05 0x00 0x01 0x00 0x00 > /dev/null
  call_ipmi "raw 0x30 0xce 0x00 0x16 0x05 0x00 0x00 0x00 0x05 0x00 0x01 0x00 0x00" "quiet"
}

# Returns :
# - 0 if third-party PCIe card Dell default cooling response is currently DISABLED
# - 1 if third-party PCIe card Dell default cooling response is currently ENABLED
# - 2 if the current status returned by ipmitool command output is unexpected
# function is_third_party_PCIe_card_Dell_default_cooling_response_disabled() {
#   THIRD_PARTY_PCIE_CARD_COOLING_RESPONSE=$(ipmitool -I $IDRAC_LOGIN_STRING raw 0x30 0xce 0x01 0x16 0x05 0x00 0x00 0x00)

#   if [ "$THIRD_PARTY_PCIE_CARD_COOLING_RESPONSE" == "16 05 00 00 00 05 00 01 00 00" ]; then
#     return 0
#   elif [ "$THIRD_PARTY_PCIE_CARD_COOLING_RESPONSE" == "16 05 00 00 00 05 00 00 00 00" ]; then
#     return 1
#   else
#     echo "Unexpected output: $THIRD_PARTY_PCIE_CARD_COOLING_RESPONSE" >&2
#     return 2
#   fi
# }

# Prepare traps in case of container exit
function gracefull_exit() {
  set_fans_default
  enable_third_party_PCIe_card_Dell_default_cooling_response
  echo "/!\ WARNING /!\ Container stopped, Dell default dynamic fan control profile applied for safety."
  exit 0
}

# Helps debugging when people are posting their output
function get_Dell_server_model() {
  #IPMI_FRU_content=$(ipmitool -I $IDRAC_LOGIN_STRING fru 2>/dev/null) # FRU stands for "Field Replaceable Unit"
  IPMI_FRU_content=$(call_ipmi "fru" "supress_errors") # FRU stands for "Field Replaceable Unit"
  if [[ -n "$TEST_MODE" ]]; then
    IPMI_FRU_content=$(cat fru.out)
  fi

  SERVER_MANUFACTURER=$(echo "$IPMI_FRU_content" | grep "Product Manufacturer" | awk -F ': ' '{print $2}')
  SERVER_MODEL=$(echo "$IPMI_FRU_content" | grep "Product Name" | awk -F ': ' '{print $2}')

  # Check if SERVER_MANUFACTURER is empty, if yes, assign value based on "Board Mfg"
  if [ -z "$SERVER_MANUFACTURER" ]; then
    SERVER_MANUFACTURER=$(echo "$IPMI_FRU_content" | tr -s ' ' | grep "Board Mfg :" | awk -F ': ' '{print $2}')
  fi

  # Check if SERVER_MODEL is empty, if yes, assign value based on "Board Product"
  if [ -z "$SERVER_MODEL" ]; then
    SERVER_MODEL=$(echo "$IPMI_FRU_content" | tr -s ' ' | grep "Board Product :" | awk -F ': ' '{print $2}')
  fi
}

# Single point call ipmi
function call_ipmi() {
  local command=$1
  local desired_verbosity=$2
  if [[ -n "$TEST_MODE" ]]; then
    desired_verbosity="TEST"
  fi
  case $desired_verbosity in
    TEST) echo "ipmitool" -I $IDRAC_LOGIN_STRING ${command} > `tty` ;;
    DEBUG) "ipmitool" -I $IDRAC_LOGIN_STRING ${command} ;;
    quiet) "ipmitool" -I $IDRAC_LOGIN_STRING ${command} 1>/dev/null ;;
    supress_errors) "ipmitool" -I $IDRAC_LOGIN_STRING ${command} 2>/dev/null ;;
    supress_all) "ipmitool" -I $IDRAC_LOGIN_STRING ${command} &>/dev/null ;;
    *) "ipmitool" -I $IDRAC_LOGIN_STRING ${command} ;;
  esac
}

function panic() {
  set_fans_default
  enable_third_party_PCIe_card_Dell_default_cooling_response
}

# Función para simular un log en la salida estándar
log() {
    # Obtener la fecha y hora actual
    local fecha=$(date +"%Y-%m-%d %H:%M:%S.%3N")

    # Nivel de registro ("DEBUG", "INFO", "WARNING", "ERROR")
    local nivel_string=$1
    local nivel=0
    case $nivel_string in
      DEBUG) nivel=$LOG_LEVEL_DEBUG ;;
      INFO) nivel=$LOG_LEVEL_INFO ;;
      WARN) nivel=$LOG_LEVEL_WARN ;;
      WARNING) nivel=$LOG_LEVEL_WARN ;;
      ERROR) nivel=$LOG_LEVEL_ERROR ;;
      *) nivel=0 ;;
    esac

    if [ "$nivel" -lt "$VERBOSITY" ]; then
        return
    fi

    # Mensaje del log
    local mensaje="$2"

    local formatted=$( printf "[%s][%-5s] %s\n" "$fecha" "$nivel_string" "$mensaje" )

    # Imprimir el log en la salida estándar
    echo "$formatted"
}

debug() {
  log "DEBUG" "$1"
}

info() {
  log "INFO" "$1"
}

warning() {
  log "WARN" "$1"
}

error() {
  log "ERROR" "$1"
}
