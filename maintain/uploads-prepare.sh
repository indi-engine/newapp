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

  # Goto project root
  cd $DOC

  # Directory where to create the zip
  dir=${1:-data}

  # Prefix to every printed message
  pref="${2:-}"

  # Source dir to be zipped
  source="custom/data/upload"

  # Target path to the zip file
  uploads="$dir/uploads.zip"

  # Create $dir if it does not exist
  [ -d "$dir" ] || mkdir -p "$dir"

  # Get glob pattern for zip file(s)
  base="${uploads%.zip}.z*"

  # Remove all .z01, .z02, etc chunks for this archive including .zip file
  rm -f $base

  # If source dir not created so far - create, make it writable for www-data user and executable
  # to allow du-command to be runnable from within apache-container on behalf of www-data user
  if [[ ! -d "$source" ]]; then
    mkdir -p "$source"
    chown -R "www-data:www-data" "$source"
    chmod +x "$source/../" "$source"
  fi

  # Get total files and folders to be added to zip
  qty=$(find $source -mindepth 1 | wc -l)
  msg="${pref}Zipping $source into $uploads..."

  # Save current dir
  dir="$(pwd)"

  # Pick GH_ASSET_MAX_SIZE from .env
  export GH_ASSET_MAX_SIZE="$(grep "^GH_ASSET_MAX_SIZE=" .env | cut -d '=' -f 2-)"

  # Goto dir to be zipped
  cd "$source"

  # If source directory (current dir) is empty
  if [ -z "$(ls -A ".")" ]; then

    # Use 7z-command to create an empty zip archive, because zip-command does not support that
    echo -n "$msg" && 7z a -tzip -bso0 -bse0 "../../../$uploads" && echo -n " Done"

  # Else
  else

    # Prepare arguments for zip-command
    args="-r -0 -s $GH_ASSET_MAX_SIZE ../../../$uploads ."

    # If we're within an interactive shell
    if [[ $- == *i* || -n "${FLASK_APP:-}" ]]; then

      # Zip with progress tracking
      zip $args | awk -v qty="$qty" -v msg="$msg" '/ adding: / {idx++; printf "\r%s %d of %d\033[K     ", msg, idx, qty; fflush();}'
      clear_last_lines 1
      echo -en "\n$msg Done"

    # Else zip with NO progress tracking
    else
      echo -n "$msg" && zip $args > /dev/null && echo -n " Done"
    fi
  fi

  # Go back to original dir
  cd "$dir"

  # Get and print zip size
  size=$(du -scbh $base 2> /dev/null | awk '/total/ {print $1}' | sed -E 's~^[0-9.]+~& ~'); echo -n ", ${size,,}b"

  # Find all chunks
  chunks=$(ls -1 $base 2> /dev/null | sort -V)

  # Print chunks qty if more than 1
  qty=$(echo "$chunks" | wc -l); if (( $qty > 1 )); then echo -n " ($qty chunks)"; else echo -n "     "; fi

  # Print newline
  echo ""
fi