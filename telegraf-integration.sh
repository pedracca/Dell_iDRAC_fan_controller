#!/bin/bash

# Function to write a row to the CSV file
function write_to_telegraf {
    local ambient_temp="$1"
    local avg_cpu="$2"
    local avg_core="$3"
    local avg_hdd="$4"
    local weighted_temp="$5"
    local demand="$6"

    # Check if the CSV file exists, if not, write headers
    if [ ! -e "$TELEGRAF_CSV_FILE" ]; then
        # Read HDD Temps(n) headers and values from the file
        hdd_temps_header=$(read_hdd_temps_from_file | head -n 1)

        # Write headers to the CSV file
        echo "Ambient Temp,AVG CPU,AVG Core,AVG HDD,Weighted Temp,Demand,$hdd_temps_header" > "$TELEGRAF_CSV_FILE"
    fi

    hdd_temps_values=$(read_hdd_temps_from_file | tail -n 1)

    # Write the row to the CSV file
    echo "$ambient_temp,$avg_cpu,$avg_core,$avg_hdd,$weighted_temp,$demand,$hdd_temps_values" >> "$TELEGRAF_CSV_FILE"
    debug "telgraf row written"
}

# Read HDD Temps(n) data from the file and generate headers and values
function read_hdd_temps_from_file {
    local header=""
    local values=""

    while read -r line; do
        # Get the header and numeric value from each line
        header_part=$(echo "$line" | sed 's/:[[:space:]][0-9]*°C//')
        numeric_part=$(echo "$line" | sed -E 's/.*: *([-+0-9.]+)..?C\b.*/\1/')

        # Add header to the header and numeric value to values
        header="$header,$header_part"
        values="$values,$numeric_part"
    done < "$TEMP_FILENAME"

    # Remove initial comma from headers and values
    header=$(echo "$header" | sed 's/^,//')
    values=$(echo "$values" | sed 's/^,//')

    echo "$header"
    echo "$values"
}

# Example usage of the write_csv_row function
# You can call this function from another script passing the fixed data as arguments

# Example:
# write_csv_row "25" "50" "45" "40" "35" "High"
