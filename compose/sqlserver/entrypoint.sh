#!/bin/bash
set -eu -o pipefail

# Make everything written to the stdout and stderr to be also written to a log file
exec > >(tee -a /var/opt/mssql/log/container.log) 2>&1

# Load functions
source /usr/local/bin/functions.sh

# Run sqlserver with preliminary init, if need
sqlserver_entrypoint "$@"
