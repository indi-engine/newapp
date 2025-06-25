#!/bin/bash
set -eu -o pipefail

# Make everything written to the stdout and stderr to be also written to a log file
exec > >(tee -a var/log/compose/wrapper/container.log) 2>&1

# Load functions
source maintain/functions.sh

# Run wrapper with preliminary init, if need
wrapper_entrypoint "$@"