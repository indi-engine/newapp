#!/bin/bash

# Load functions
source maintain/functions.sh

# Set the trap: Call on_exit function when the script exits
trap on_exit EXIT

# If docker is installed - it means restore-command is being run on host
if command -v docker >/dev/null 2>&1; then

  # Add -i if we're in interactive shell
  [[ $- == *i* ]] && bash_flags=(-i) || bash_flags=()

  # Execute restore-command within the container environment passing all arguments, if any
  docker compose exec -it -e TERM="$TERM" wrapper bash "${bash_flags[@]}" "maintain/$(basename "${BASH_SOURCE[0]}")" $@

# Else it means we're in the wrapper-container, so proceed with the restore
else

  # Shortcuts
  dir="${1:-data}"
  host="$MYSQL_HOST"
  user="$MYSQL_USER"
  pass="$MYSQL_PASSWORD"
  name="$MYSQL_DATABASE"
  dump="$dir/$MYSQL_DUMP"
  pref="${2:-}"

  # Goto project root
  cd "$DOC"

  # Trim .gz from dump filename
  sql=$(echo "$dump" | sed 's/\.gz$//')

  # Put password into env to solve the warning message:
  # 'mysqldump: [Warning] Using a password on the command line interface can be insecure.'
  export MYSQL_PWD="$pass"

  # Estimate export as number of records to be dumped
  msg="${pref}Calculating approximate qty of total rows..."; echo $msg
  total=0; tables=0
  args="-h $host -u $user -N -e"
  for table in $(mysql $args 'SHOW TABLES FROM `'$name'`;'); do
    count=$(mysql $args "SELECT TABLE_ROWS FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_SCHEMA = '$name' AND TABLE_NAME = '$table';")
    (( total+=count )) || true
    (( tables++ )) || true
    clear_last_lines 1
    echo -n "$msg "; printf "%'d" "$total"; echo " in $tables tables"
  done

  # Target gz file path
  gz="$sql.gz"
  base=$gz*

  # Remove existing gz file with chunks, if any
  rm -f $base*

  # Pick GH_ASSET_MAX_SIZE from .env
  export GH_ASSET_MAX_SIZE="$(grep "^GH_ASSET_MAX_SIZE=" .env | cut -d '=' -f 2-)"

  # Export dump with printing progress
  [ -d "$dir" ] || mkdir -p "$dir"
  msg="${pref}Exporting $(basename "$gz") into $dir/ dir...";
  mysqldump --single-transaction -h $host -u $user -y $name \
  | tee >(grep --line-buffered '^INSERT INTO' \
      | awk -v total="$total" -v msg="$msg" '{
          count += gsub(/\),\(/, "&") + 1
          percent = int((count / total) * 100)
          if (percent != last) {
            printf "\r%s %d / %d (%d%%)", msg, count, total, percent
            fflush()
            last = percent
          }
        }' >&2) \
  | gzip | split --bytes=${GH_ASSET_MAX_SIZE^^} --numeric-suffixes=1 - $gz

  # Unset from env
  unset MYSQL_PWD

  # Exit if above command failed
  exit_code=$?; if [[ $exit_code -ne 0 ]]; then echo "mysqldump exited with code $exit_code"; exit $exit_code; fi

  echo ""
  clear_last_lines 1
  echo -n "$msg Done"

  # Remove suffix from single chunk
  chunks=($base); if [ "${#chunks[@]}" -eq 1 ]; then mv "${chunks[0]}" $gz; fi

  # Get and print gz size
  size=$(du -scbh $base 2> /dev/null | awk '/total/ {print $1}' | sed -E 's~^[0-9.]+~& ~'); echo -n ", ${size,,}b"

  # Find all chunks
  chunks=$(ls -1 $base 2> /dev/null | sort -V)

  # Print chunks qty if more than 1
  qty=$(echo "$chunks" | wc -l); if (( $qty > 1 )); then echo -n " ($qty chunks)"; fi

  # Print newline
  echo ""
fi