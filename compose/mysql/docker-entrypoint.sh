#!/bin/bash

# If wget is not yet installed
if ! command -v wget &>/dev/null; then

  # Install it
  apt-get update && apt-get install -y wget

  # Print which dump is going to be imported
  echo "MYSQL_DUMP is $MYSQL_DUMP";

  # Change dir
  cd /docker-entrypoint-initdb.d

  # Array of other sql files to be imported
  declare -a import=("maxwell.sql")

  # If MYSQL_DUMP is an URL
  if [[ $MYSQL_DUMP == http* ]]; then

    # Download it right here
    echo "Fetching MySQL dump from $MYSQL_DUMP..." && wget --no-check-certificate "$MYSQL_DUMP"

  # Else assume it's a local path pointing to some file inside
  # /docker-entrypoint-initdb.d/custom/ directory mapped as a volume
  # from sql/ directory on the docker host machine
  else

    # Shortcut
    dumpfile="custom/$MYSQL_DUMP"

    # If that local path to sql-dump file really exists in custom/ and that file is NOT empty
    if [ -f $dumpfile ] && [ -s $dumpfile ]; then

      # Copy that file here for it to be imported, as files from subdirectories are ignored while import
      cp $dumpfile . && echo "File /docker-entrypoint-initdb.d/$dumpfile copied to the level up"

    # Else
    else

      # Use system.sql
      import+=("system.sql") && echo "The file specified in \$MYSQL_DUMP does not exist or is empty, so using system.sql"
    fi
  fi

  # Download the SQL dump files
  for filename in "${import[@]}"; do
    url="https://github.com/indi-engine/system/raw/master/sql/${filename}"
    echo "Fetching from $url..." && wget "$url"
  done

  # Append touch-command to create empty '/var/lib/mysql/init.done'-file after init is done to use in healthcheck
  sed -i 's~Ready for start up."~&\n\t\t\ttouch /var/lib/mysql/init.done~' /usr/local/bin/docker-entrypoint.sh
fi

# Call the original entrypoint script
/usr/local/bin/docker-entrypoint.sh "$@"
