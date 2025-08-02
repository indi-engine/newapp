#!/bin/bash

# Shortcuts
dir=${1:-data}
host=mysql
user=$MYSQL_USER
pass=$MYSQL_PASSWORD
name=$MYSQL_DATABASE
dump="$dir/$MYSQL_DUMP"
pref="${2:-}"

# Clear last X lines
clear_last_lines() {
  for ((i = 0; i < $1; i++)); do tput cuu1 && tput el; done
}

# Goto project root
cd $DOC

# Trim .gz from dump filename
sql=$(echo "$dump" | sed 's/\.gz$//')

# Put password into env to solve the warning message:
# 'mysqldump: [Warning] Using a password on the command line interface can be insecure.'
export MYSQL_PWD=$pass

# Estimate export as number of records to be dumped
msg="${pref}Calculating total rows..."; echo $msg
total=0; tables=0
args="-h $host -u $user -N -e"
for table in $(mysql $args 'SHOW TABLES FROM `'$name'`;'); do
  count=$(mysql $args "SELECT TABLE_ROWS FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_SCHEMA = '$name' AND TABLE_NAME = '$table';")
  (( total+=count )) || true
  (( tables++ )) || true
  clear_last_lines 1
  echo -n "$msg "; printf "%'d" "$total"; echo " in $tables tables"
done

# Export dump with printing progress
[ -d "$dir" ] || mkdir -p "$dir"
msg="${pref}Exporting $(basename "$sql") into $dir/ dir...";
mysqldump --single-transaction -h $host -u $user -y $name | \
  tee $sql | \
  grep --line-buffered '^INSERT INTO' | \
  awk -v total="$total" -v msg="$msg" '{
    count += gsub(/\),\(/, "&") + 1
    percent = int((count / total) * 100)
    if (percent != last) {
        printf "\r%s %d / %d (%d%%)", msg, count, total, percent
        fflush()
        last = percent
    }
  }'

# Exit if above command failed
exit_code=$?; if [[ $exit_code -ne 0 ]]; then echo "mysqldump exited with code $exit_code"; exit $exit_code; fi

echo ""
clear_last_lines 1
echo -n "$msg Done"
size=$(du -scbh $sql 2> /dev/null | awk '/total/ {print $1}' | sed -E 's~^[0-9.]+~& ~'); echo ", ${size,,}b"

# Unset from env
unset MYSQL_PWD

# Target gz file path
gz="$sql.gz"
base=$gz*

# Remove existing gz file with chunks, if any
rm -f $base*

# Pick GH_ASSET_MAX_SIZE from .env
export GH_ASSET_MAX_SIZE="$(grep "^GH_ASSET_MAX_SIZE=" .env | cut -d '=' -f 2-)"

# Gzip dump with splitting into chunks
msg="${pref}Gzipping $(basename "$sql")"
pv --name "$msg" -pert $sql | gzip | split --bytes=${GH_ASSET_MAX_SIZE^^} --numeric-suffixes=1 - $gz
clear_last_lines 1
echo "$msg... Done"

# Remove original sql file
rm -f $sql

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