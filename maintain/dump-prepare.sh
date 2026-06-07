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
  user="$DB_APP_USER"
  pass="$DB_APP_PASSWORD"
  name="$DB_NAME"
  pref="${2:-}"
  cli="$(get_engine_cli)"

  # Goto project root
  cd "$DOC"

  # Prepare DBE-specific shortcuts
  if [[ "$engine" == "postgres" ]]; then
    pwdenv="PGPASSWORD"
    args="-h $host -U $user -t -q -d $name -c"
    schemas="system public"
    rows="SELECT SUM(c.reltuples::bigint) FROM pg_catalog.pg_class c JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace WHERE c.relkind = 'r' AND n.nspname IN ('${schemas/ /"','"}')"
    dump_bin="pg_dump"
    dump_cmd="$dump_bin -h $host -U $user -d $name -n ~schema~ --no-owner --no-acl --no-publications --inserts --rows-per-insert=1000"
  else
    pwdenv="MYSQL_PWD"
    args="-h $host -u $user -N -e"
    schemas="system $name"
    rows="SELECT SUM(TABLE_ROWS) FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_SCHEMA IN ('${schemas/ /"','"}')"
    case "$engine" in
      mariadb) dump_bin="mariadb-dump" ;;
      *)       dump_bin="mysqldump" ;;
    esac
    dump_cmd="$dump_bin -h $host -u $user -y ~schema~ --single-transaction"
  fi

  # Query shortcut
  query="$cli $args"

  # Put password into env
  export "${pwdenv}=${pass}"

  # Estimate export as number of records to be dumped
  msg="${pref}Calculating approximate qty of total rows..."; echo $msg
  qty="$($query "$rows")"; qty=${qty//[[:space:]]/};
  tbl="$($query "${rows/SUM/COUNT}")"; tbl=${tbl//[[:space:]]/};
  clear_last_lines 1
  echo -n "$msg "; printf "%'d" "$qty"; echo " in $tbl tables"

  # Pick GH_ASSET_MAX_SIZE from .env
  export GH_ASSET_MAX_SIZE="$(grep "^GH_ASSET_MAX_SIZE=" .env | cut -d '=' -f 2-)"

  # Foreach schema
  for schema in $schemas; do

    # Shortcuts
    dump="$dir/$schema.sql.gz"
    base=$dump*

    # Remove existing gz file with chunks, if any
    rm -f $base*

    # Export dump with printing progress
    [ -d "$dir" ] || mkdir -p "$dir"
    msg="${pref}Exporting $(basename "$dump") into $dir/ dir...";
    ${dump_cmd/~schema~/"$schema"} | tee >(grep --line-buffered '^INSERT INTO' | awk -v total="$total" -v msg="$msg" '{
        count += gsub(/\),\(/, "&") + 1
        percent = int((count / total) * 100)
        if (percent != last) {
          printf "\r%s %d / %d (%d%%)", msg, count, total, percent
          fflush()
          last = percent
        }
      }' >&2) \
    | gzip | split --bytes=${GH_ASSET_MAX_SIZE^^} --numeric-suffixes=1 - $dump

    # Exit if above command failed
    exit_code=${PIPESTATUS[0]}; if [[ $exit_code -ne 0 ]]; then echo "$dump_bin exited with code $exit_code"; exit $exit_code; fi

    echo ""
    clear_last_lines 1
    echo -n "$msg Done"

    # Remove suffix from single chunk
    chunks=($base); if [ "${#chunks[@]}" -eq 1 ]; then mv "${chunks[0]}" $dump; fi

    # Get and print gzipped dump size
    size=$(du -scbh $base 2> /dev/null | awk '/total/ {print $1}' | sed -E 's~^[0-9.]+~& ~'); echo -n ", ${size,,}b"

    # Find all chunks
    chunks=$(ls -1 $base 2> /dev/null | sort -V)

    # Print chunks qty if more than 1
    qty=$(echo "$chunks" | wc -l); if (( $qty > 1 )); then echo -n " ($qty chunks)"; fi

    # Print newline
    echo ""
  done

  # Unset from env
  unset "$pwdenv"
fi