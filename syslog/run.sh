#!/bin/bash

if [ -z "$1" ] || [ -z "$2" ]; then
    echo "Usage: $0 <ntopng IP> <ntopng syslog port>"
    echo "Example: $0 127.0.0.1 5140"
fi

TODAY=$(date +'%Y-%m-%d')

cat suricata.log | sed -e "s:2022-06-11:${TODAY}:g" | netcat $1 $2
