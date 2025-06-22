#!/bin/bash
set -eu -o pipefail

# Make everything written to the stdout and stderr to be also written to a log file
exec > >(tee -a /var/log/mysql/container.log) 2>&1

# Load functions
source /usr/local/bin/functions.sh

# Run mysql with preliminary init, if need
mysql_entrypoint "$@"