#!/bin/bash

# Clear the terminal log
clear

# Get directory where there this file is located
__dir__="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Goto parent dir
cd $__dir__"/../"

# Load function
source maintain/functions.sh

# Prepare .env file out of .env.dist file with prompting for values where needed
prepare_env "${1:-}"

# Get to original directory from where execution was started
cd $OLDPWD