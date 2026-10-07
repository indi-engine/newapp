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
  databases="system $name"

  # Goto project root
  cd "$DOC"

  # Prepare DBE-specific shortcuts
  if [[ "$engine" == "postgres" ]]; then
    pwdenv="PGPASSWORD"
    hu="-h $host -U $user"
   #args="$hu -d $name -t -q -c"
    args="$hu -d ~name~ -t -q -c"
    schemas="system public"
   #rows="SELECT SUM(c.reltuples::bigint) FROM pg_catalog.pg_class c JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace WHERE c.relkind = 'r' AND n.nspname IN ('${schemas/ /"','"}')"
    rows="SELECT SUM(c.reltuples::bigint) FROM pg_catalog.pg_class c JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace WHERE c.relkind = 'r' AND n.nspname IN ('public')"
    tables="${rows/SUM/COUNT}"
    dump_ext="sql.gz"
    dump_bin="pg_dump"
   #dump_cmd="$dump_bin -h $host -U $user -d $name -n ~schema~ --no-owner --no-acl --no-publications --inserts --rows-per-insert=1000"
    dump_cmd="$dump_bin -h $host -U $user -d ~name~ -n public --no-owner --no-acl --no-publications --inserts --rows-per-insert=1000"
    gzip_cmd() { grep -vE "^(CREATE SCHEMA|COMMENT ON SCHEMA)" | gzip; }
  elif [[ "$engine" == "sqlserver" ]]; then
    pwdenv="SQLCMDPASSWORD"
    hu="-S $host -U $user"
    args="$hu -d ~name~ -C -b -h -1 -W -Q"
    rows="SET NOCOUNT ON; SELECT COALESCE(SUM(p.rows), 0) FROM sys.tables t JOIN sys.schemas s ON s.schema_id=t.schema_id JOIN sys.partitions p ON p.object_id=t.object_id AND p.index_id IN (0,1) WHERE s.name = N'dbo'"
    tables="SET NOCOUNT ON; SELECT COUNT(*) FROM sys.tables t JOIN sys.schemas s ON s.schema_id=t.schema_id WHERE s.name = N'dbo'"
    dump_ext="bak"
    dump_bin="sqlcmd"
    dump_cmd="$dump_bin $hu -d master -C -b"
    dump_sql="BACKUP DATABASE [~name~] TO DISK = N'/$dir/~name~.$dump_ext' WITH INIT, COPY_ONLY, COMPRESSION, CHECKSUM, STATS = 1;"
  else
    pwdenv="MYSQL_PWD"
    hu="-h $host -u $user"
    args="$hu -D ~name~ -N -e"
    rows="SELECT SUM(TABLE_ROWS) FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_SCHEMA = DATABASE()"
    tables="${rows/SUM/COUNT}"
    dump_ext="sql.gz"
    case "$engine" in
      mariadb) dump_bin="mariadb-dump" ;;
      *)       dump_bin="mysqldump" ;;
    esac
    dump_cmd="$dump_bin $hu -y ~name~ --single-transaction"
    gzip_cmd() { gzip; }
  fi

  # Query shortcut
  query="$cli $args"

  # Small backup verification function. Really used only for sqlserver
  verify_backup() {
    if [[ "$engine" == "sqlserver" ]]; then
      $dump_bin $hu -d master -C -b > /dev/null <<-SQL
				RESTORE VERIFYONLY FROM DISK = N'/$dump' WITH CHECKSUM;
			SQL
    else
      return 0
    fi
  }

  # Put password into env
  export "${pwdenv}=${pass}"

  # Estimate export as number of records to be dumped
  msg="${pref}Calculating approximate qty of total rows..."; echo $msg
  qty=0; tbl=0
  for name in $databases; do
    db_query="${query/~name~/$name}"
    db_qty="$($db_query "$rows")";   db_qty=${db_qty//[[:space:]]/}
    db_tbl="$($db_query "$tables")"; db_tbl=${db_tbl//[[:space:]]/}
    qty=$((qty + db_qty))
    tbl=$((tbl + db_tbl))
  done
  clear_last_lines 1
  echo -n "$msg "; printf "%'d" "$qty"; echo " in $tbl table(s)"

  # Pick GH_ASSET_MAX_SIZE from .env
  export GH_ASSET_MAX_SIZE="$(grep "^GH_ASSET_MAX_SIZE=" .env | cut -d '=' -f 2-)"

  # Foreach schema
  for name in $databases; do

    # Shortcuts
    dump="$dir/$name.$dump_ext"
    base=$dump*

    # Remove existing backup with chunks (if any) and create dir if missing
    rm -f $base*; [ -d "$dir" ] || mkdir -p "$dir"

    # Export dump with printing progress
    msg="${pref}Exporting $(basename "$dump") into $dir/ dir...";
    if [[ "$engine" == "sqlserver" ]]; then

      # Make target directory writable by sqlserver
      chmod a+w "$dir"

      # SQL Server can return a non-zero exit code after writing a valid .bak on Docker bind mounts,
      # e.g. DiskChangeFileSize error 31. Let RESTORE VERIFYONLY below decide if the backup is usable.
      set +e
      ${dump_cmd//~name~/"$name"} <<< "${dump_sql//~name~/"$name"}" | awk -v msg="$msg" '
        /^[0-9]+ percent processed\./ {
          percent = $1
          printf "\r%s %d%%", msg, percent > "/dev/stderr"
          fflush("/dev/stderr")
          next
        }
        /^Processed [0-9]+ pages for database / { next }
        /^Msg 3634, / { next }
        /DiskChangeFileSize/ && /31\(A device attached to the system is not functioning\.\)/ { next }
        /^Msg 3013, / { next }
        /^BACKUP DATABASE is terminating abnormally\./ { next }
        { print > "/dev/stderr" }
      '
      exit_code=${PIPESTATUS[0]}
      set -e
    else
      ${dump_cmd//~name~/"$name"} | tee >(grep --line-buffered '^INSERT INTO' | awk -v total="$qty" -v msg="$msg" '{
          count += gsub(/\),\(/, "&") + 1
          percent = int((count / total) * 100)
          if (percent != last) {
            printf "\r%s %d / %d (%d%%)", msg, count, total, percent
            fflush()
            last = percent
          }
        }' >&2) \
      | gzip_cmd | split --bytes=${GH_ASSET_MAX_SIZE^^} --numeric-suffixes=1 - $dump
    fi

    # Exit if above command failed
    exit_code=${PIPESTATUS[0]};
    if [[ $exit_code -ne 0 ]] && ! verify_backup "$name"; then
      echo "$dump_bin exited with code $exit_code"
      exit $exit_code
    fi

    echo ""
    clear_last_lines 1
    echo -n "$msg Done"

    # Remove suffix from single chunk
    chunks=($base); if [[ "${#chunks[@]}" -eq 1 && "${chunks[0]}" != "$dump" ]]; then mv "${chunks[0]}" $dump; fi

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
