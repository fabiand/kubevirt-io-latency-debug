#!/bin/bash

# Check if pod name is provided
if [ -z "$1" ]; then
    echo "Usage: $0 <pod_name> [interval_seconds]"
    echo "  pod_name: Name of the pod to monitor"
    echo "  interval_seconds: Monitoring duration in seconds (default: 120)"
    exit 1
fi

POD="$1"
INTERVAL="${2:-120}"  # Default to 120 seconds if not provided

# Get all virtio-backend devices
QDEVS=`oc rsh $POD virsh qemu-monitor-command 1 --pretty '{"execute": "query-block" }' 2>/dev/null | grep virtio-backend | cut -d '"' -f4`

# Define boundaries for histograms (in nanoseconds)
# 10ms, 100ms, 1s, 10s, 60s
BINS="[10000000, 100000000, 1000000000, 10000000000, 60000000000]"

for qdev in $QDEVS; do
    echo "Enabling histogram on $qdev..."
    oc rsh $POD virsh qemu-monitor-command 1 --pretty '{
        "execute": "block-latency-histogram-set",
        "arguments": {
            "id": "'$qdev'",
            "boundaries-read": '$BINS',
            "boundaries-write": '$BINS',
            "boundaries-flush": '$BINS'
        }
    }' > /dev/null 2>&1
done

echo ""
echo "Monitoring for $INTERVAL seconds..."
sleep $INTERVAL

echo ""
echo "Collecting statistics..."
STATS=$(oc rsh $POD virsh qemu-monitor-command 1 --pretty '{"execute": "query-blockstats" }' 2>&1 | grep -v "^Authorization" | grep -v "^Check if polkit")

# Save raw output for debugging
echo "$STATS" > /tmp/blockstats.json

# Validate we got valid JSON
if ! echo "$STATS" | jq empty 2>/dev/null; then
    echo "Error: Failed to get valid JSON from query-blockstats command"
    echo "Output saved to /tmp/blockstats.json for debugging"
    exit 1
fi

# Check if jq is available
if ! command -v jq &> /dev/null; then
    echo "Error: jq is required but not installed. Please install jq to parse JSON."
    echo "Raw JSON output saved to /tmp/blockstats.json"
    exit 1
fi

for qdev in $QDEVS; do
    echo ""
    echo "Device: $qdev"

    # Extract the stats for this specific device
    DEVICE_STATS=$(echo "$STATS" | jq -r --arg qdev "$qdev" '.return[] | select(.qdev == $qdev) | .stats')

    if [ -z "$DEVICE_STATS" ] || [ "$DEVICE_STATS" == "null" ]; then
        echo "No stats found for device $qdev"
        continue
    fi

    # Extract histogram bins for all operation types
    declare -A HIST_DATA

    for op_type in rd wr flush; do
        BINS=$(echo "$DEVICE_STATS" | jq -r ".${op_type}_latency_histogram.bins // [] | @csv" | tr ',' ' ')

        if [ -n "$BINS" ] && [ "$BINS" != "null" ]; then
            read -ra BIN_ARRAY <<< "$BINS"

            # Store bins for this operation type
            for i in {0..5}; do
                HIST_DATA["${op_type}_${i}"]="${BIN_ARRAY[$i]:-0}"
            done
        fi
    done

    # Display combined table
    printf "%-15s %12s %12s %12s\n" "Latency Range" "READ" "WRITE" "FLUSH"

    # Display each latency range with all three operation types
    for range_idx in 0 1 2 3 4 5; do
        case $range_idx in
            0) range_label="<10ms" ;;
            1) range_label="10-100ms" ;;
            2) range_label="100ms-1s" ;;
            3) range_label="1-10s" ;;
            4) range_label="10-60s" ;;
            5) range_label=">60s" ;;
        esac

        rd_val="${HIST_DATA[rd_${range_idx}]:-0}"
        wr_val="${HIST_DATA[wr_${range_idx}]:-0}"
        flush_val="${HIST_DATA[flush_${range_idx}]:-0}"

        printf "%-15s %12d %12d %12d\n" "$range_label" "$rd_val" "$wr_val" "$flush_val"
    done
done

echo ""
for qdev in $QDEVS; do
    echo "Disabling histogram on $qdev..."
    oc rsh $POD virsh qemu-monitor-command 1 --pretty '{
        "execute": "block-latency-histogram-set",
        "arguments": {
            "id": "'$qdev'"
        }
    }' > /dev/null 2>&1
done

echo ""
echo "Raw JSON output saved to /tmp/blockstats.json"
