#!/bin/bash

# If wget is not yet installed
if ! command -v wget &>/dev/null; then

  # Install it
  apt-get update && apt-get install -y wget

  # Common URL prefix for the SQL dump files
  COMMON_URL="https://github.com/indi-engine/system/raw/master/sql/"

  # Array of SQL dump filenames
  declare -a sql_filenames=(
    "system.sql"
    "maxwell.sql"
  )

  # Download the SQL dump files
  for filename in "${sql_filenames[@]}"; do
    url="${COMMON_URL}${filename}"
    echo "Fetching $filename from $url..."
    wget -O "/docker-entrypoint-initdb.d/$filename" "$url"
  done

fi

# Call the original entrypoint script
/usr/local/bin/docker-entrypoint.sh "$@"
