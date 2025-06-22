#!/bin/bash

# Goto project root
cd $DOC

# Directory where to create the zip
dir=${1:-data}

# Source dir to be zipped
source="custom/data/upload"

# Target path to the zip file
uploads="$dir/uploads.zip"

# Create $dir if it does not exist
[ -d "$dir" ] || mkdir -p "$dir"

# Get glob pattern for zip file(s)
base="${uploads%.zip}".z*

# Remove all .z01, .z02, etc chunks for this archive including .zip file
rm -f $base

# Get total files and folders to be added to zip
qty=$(find $source -mindepth 1 | wc -l)
msg="Zipping $source into $uploads..."

# Save current dir and goto dir to be zipped
dir="$(pwd)"; cd "$source"

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
    zip $args | awk -v qty="$qty" -v msg="$msg" '/ adding: / {idx++; printf "\r%s %d of %d\033[K", msg, idx, qty; fflush();}'
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
qty=$(echo "$chunks" | wc -l); if (( $qty > 1 )); then echo -n " ($qty chunks)"; fi

# Print newline
echo ""