#!/bin/bash

# Check if nvidia-smi exists
if command -v nvidia-smi &> /dev/null; then
    # Get GPU usage from nvidia-smi
    usage=$(nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader,nounits)
    echo "$usage"
# Check if rocm-smi exists
elif command -v rocm-smi &> /dev/null; then
    # Get GPU usage from rocm-smi
    usage=$(rocm-smi --showuse | grep "GPU use" | awk '{print $3}' | tr -d '%')
    echo "$usage"
else
    echo "0"
fi 