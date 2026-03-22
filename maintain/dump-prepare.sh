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
  engine="$(get_env "DB_ENGINE")"
  dir="${1:-data}"
  host="$DB_HOST"
  user="$DB_USER"
  pass="$DB_PASSWORD"
  name="$DB_NAME"
  dump="$dir/$DB_DUMP"
  pref="${2:-}"

  # Goto project root
  cd "$DOC"

  # Trim .gz from dump filename
  sql=$(echo "$dump" | sed 's/\.gz$//')

  if [[ "$engine" == "mysql" ]]; then
    pwdenv="MYSQL_PWD"
    args="-h $host -u $user -N -e"
    query="mysql $args"
    tables='SHOW TABLES FROM `'$name'`'
    recordQty="SELECT TABLE_ROWS FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_SCHEMA = '$name' AND TABLE_NAME = '---'"
    dump_bin="mysqldump"
    dump_cmd="$dump_bin -h $host -u $user -y $name --single-transaction"
  elif [[ "$engine" == "postgres" ]]; then
    pwdenv="PGPASSWORD"
    args="-h $host -U $user -t -q -c"
    query="psql $args"
    tables="SELECT tablename FROM pg_tables WHERE schemaname = 'public'"
    recordQty="SELECT reltuples::bigint FROM pg_class WHERE relname = '---'"
    dump_bin="pg_dump"
    dump_cmd="$dump_bin -h $host -U $user -d $name --no-owner --no-acl --inserts --rows-per-insert=1000"
  fi

  # Put password into env
  export "${pwdenv}=${pass}"

  # Estimate export as number of records to be dumped
  msg="${pref}Calculating approximate qty of total rows..."; echo $msg
  total=0; tableQty=0
  for table in $($query "$tables"); do
    count="$($query "${recordQty/---/"$table"}")"
    count=${count//[[:space:]]/}
    (( total+=count )) || true
    (( tableQty++ )) || true
    clear_last_lines 1
    echo -n "$msg "; printf "%'d" "$total"; echo " in $tableQty tables"
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
  $dump_cmd | tee >(grep --line-buffered '^INSERT INTO' | awk -v total="$total" -v msg="$msg" '{
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
  unset "$pwdenv"

  # Exit if above command failed
  exit_code=${PIPESTATUS[0]}; if [[ $exit_code -ne 0 ]]; then echo "$dump_bin exited with code $exit_code"; exit $exit_code; fi

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