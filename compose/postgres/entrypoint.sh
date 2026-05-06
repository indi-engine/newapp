#!/bin/bash
set -eu -o pipefail

# Create log file and set postgres to be it's owner
log="/var/log/postgresql/postgresql.log"; touch "$log"; chown postgres:postgres "$log"

# Make everything written to the stdout and stderr to be also written to a log file
exec > >(tee -a /var/log/postgresql/container.log) 2>&1

# Load functions
source /usr/local/bin/functions.sh

# Run postgres with preliminary init, if need
postgres_entrypoint "$@"