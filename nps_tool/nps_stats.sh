#!/bin/bash
set -e
#set -x
# Check for input file
if [ $# -ne 1 ]; then
    echo "Usage: $0 <input_csv_file>"
    echo " This tool loads energy consumption data from the file supplied and"
    echo " calculates total price and unit price by downloading the energy prices"
    echo " data and matching the specific hourly consumption with hourly prices."
    exit 1
fi
export LC_NUMERIC=en_US 2>/dev/null
INPUT_FILE="$1"
TMP_PRICE_FILE="price_data.csv"

header_lines=1
# Figure out header lines count
while IFS=';' read -r time name consumption remark; do
    case "$time" in
        *'.'*'.'*' '*':'*) break;;
        *) header_lines=$(( header_lines + 1 ));;
    esac
done < $INPUT_FILE

# Extract first and last timestamps
FIRST_LINE=$(head -n ${header_lines} "$INPUT_FILE" | tail -n 1)
LAST_LINE=$(tail -n 1 "$INPUT_FILE")

START_TIME=$(echo "$FIRST_LINE" | cut -d';' -f1)
END_TIME=$(echo "$LAST_LINE" | cut -d';' -f1)

echo "Start line: $header_lines, Start: $START_TIME End: $END_TIME"

to_iso8601() {
    [ $# -eq 2 ] && minus=$2 || minus=0
    if ! date -j -u -v-${minus}H -f "%d.%m.%Y %H:%M:%S" "${1}:00" +%Y-%m-%dT%H:%M:%S.000Z 2>/dev/null; then
        date -d "${1:6:4}-${1:3:2}-${1:0:2}T${1:11:2}:${1:14:2}:00+0${minus}:00" +"%Y-%m-%dT%H:%M:%S.000Z"
    fi 
}


START_ISO=$(to_iso8601 "$START_TIME" 3)
END_ISO=$(to_iso8601 "$END_TIME")

# We could query price data and cache it if needed
#curl -s "https://dashboard.elering.ee/api/nps/price/csv?start=${START_ISO}&end=${END_ISO}&fields=ee" -o "$TMP_PRICE_FILE"

# Create arrays for timestamps and prices for price lookup
# This is needed for older bash versions when hashmap arrays are not available
times=()
prices=()
skipper=1 # how many header lines to skip from prices data
while IFS=';' read -r _ local_time price; do
    [ $skipper -gt 0 ] && skipper=$(( skipper - 1 )) && continue
    times+=("${local_time//\"/}")
    val=${price//\"/}
    val=${price/,/.}
    thisprice=$(awk "BEGIN {printf \"%.4f\", $val / 1000}")
    prices+=(${thisprice/,/.})
done < <(curl -s "https://dashboard.elering.ee/api/nps/price/csv?start=${START_ISO}&end=${END_ISO}&fields=ee" -o -)
echo "Prices read, now processing..."
pindex=0
get_unit_price() {
    while [ $pindex -le ${#prices[@]} ]; do
        nextindex=$(( pindex + 1 ))
        if [[ "${1}" < "${times[$nextindex]}" ]]; then
            current_price=${prices[$pindex]}
            break
        fi
        pindex=$nextindex
    done
}

# Process input file and write output
while IFS=';' read -r time name consumption remark; do
    consumption_val=${consumption/,/.};
    get_unit_price "$time"
    unit_price=$current_price
    total_consumption=$(awk "BEGIN {printf \"%.4f\", $total_consumption + $consumption_val}")
    total_price=$(awk "BEGIN {printf \"%.4f\", $total_price + ($consumption_val * $unit_price)}")
done < <(tail -n +${header_lines} "$INPUT_FILE")

vat="26"
total_price_vat=$(awk "BEGIN {printf \"%.4f\", $total_price * 1.$vat}")
average_price=$(awk "BEGIN {printf \"%.4f\", $total_price / $total_consumption}")
average_price_vat=$(awk "BEGIN {printf \"%.4f\", $average_price * 1.$vat }")
cat <<-EOF
Total consumption: $total_consumption kWh
Prices (VAT $vat%):
Excl. VAT total: $total_price €, unit: $average_price €/kWh
Incl. VAT total: $total_price_vat €, unit: $average_price_vat €/kWh
EOF
# Cleanup
#rm "$TMP_PRICE_FILE"
