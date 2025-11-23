#!/bin/bash

# Declare array of [repo name => releases qty] pairs
declare -gA releaseQty=()

# Windows: Git Bash specific fix
GIT_PS1_SHOWCONFLICTSTATE=

# Colors
r="\e[31m" # red
g="\e[36m" # cyan
d="\e[0m"  # default
gray='\033[38;5;240m' #lightgray

# Get the whole project up and running
getup() {

  # Setup the docker compose project
  set +e; docker compose up -d; exit_code=$?;

  # If failed - return error
  if [[ $exit_code -ne 0 ]]; then return 1; else set -e; fi

  # Run pre-getup hook, if exists
  if [[ -f ~/.indi/pre-getup ]]; then
    source ~/.indi/pre-getup
  fi

  # Import files mentioned in MYSQL_DUMP with preliminary download, if need
  mysql_import

  # Pick LETS_ENCRYPT_DOMAIN and EMAIL_SENDER_DOMAIN from .env file, if possible
  LETS_ENCRYPT_DOMAIN="$(get_env "LETS_ENCRYPT_DOMAIN")"
  EMAIL_SENDER_DOMAIN="$(get_env "EMAIL_SENDER_DOMAIN")"
  if [[ -z "$EMAIL_SENDER_DOMAIN" ]]; then EMAIL_SENDER_DOMAIN="$LETS_ENCRYPT_DOMAIN"; fi

  # If DKIM-keys are expected to be created
  if [[ ! -z "$EMAIL_SENDER_DOMAIN" ]]; then

    # If DKIM-keys are not already created
    if ! docker compose exec wrapper sh -c "cat /etc/opendkim/trusted.hosts" | grep -q "${EMAIL_SENDER_DOMAIN##* }"; then

      # Shortcuts
      local wait="Waiting for DKIM-keys to be prepared.."

      # Wait while DKIM-keys are ready
      while ! docker compose exec wrapper sh -c "cat /etc/opendkim/trusted.hosts" | grep -q "${EMAIL_SENDER_DOMAIN##* }"; do
        [[ -n $wait ]] && echo -n "$wait" && wait="" || echo -n "."
        sleep 1
      done
      echo ""

      # Print mail config
      docker compose exec wrapper bash -c "source maintain/mail-config.sh"
    fi
  fi

  # Force current directory to be the default directory
  if [[ -f /root/.bashrc ]]; then
    echo "cd "$(pwd) >> /root/.bashrc
  fi

  # If .env.hard file does not yet exist - create it as a copy of .env.dist but with a pre-filled value for GH_TOKEN_CUSTOM_RW
  #if [[ ! -f ".env.hard" ]]; then
  #  cp ".env.dist" ".env.hard"
  #  GH_TOKEN_CUSTOM_RW=$(get_env "GH_TOKEN_CUSTOM_RW")
  #  if [[ ! -z $GH_TOKEN_CUSTOM_RW ]]; then
  #    sed -i "s~GH_TOKEN_CUSTOM_RW=~&${GH_TOKEN_CUSTOM_RW:-}~" ".env.hard"
  #  fi
  #fi

  # If SSL cert is expected to be created
  if [[ ! -z "$LETS_ENCRYPT_DOMAIN" ]]; then

    # Shortcut
    wait="Waiting for SSL-certificate for $LETS_ENCRYPT_DOMAIN to be prepared.."

    # If certbot is added to crontab - it means SSL step is done (successful or not)
    while ! docker compose exec apache sh -c "crontab -l 2>/dev/null | grep -q certbot"; do
      [[ -n $wait ]] && echo -n "$wait" && wait="" || echo -n "."
      sleep 2
    done
    echo ""
  fi

  # Print newline and URL to proceed
  echo -e "Your app is here: ${g}$(get_self_href)${d}"

  # Make sure 'custom/data/upload' dir is created and filled, if does not exist
  init_uploads_if_need

  # If $GH_TOKEN_CUSTOM_RW is set but there are no releases yet in the current repo due to it's
  # a forked or generated repo and it's a very first time of the instance getting
  # up and running for the current repo - backup current state into a very first own release,
  # so that any further deployments won't rely on parent repo releases anymore
  if [[ "$(get_current_repo)" != "indi-engine/newapp" ]]; then
    make_very_first_release_if_need
  fi

  # Periodically check if var/restart file appeared, and when yes - initiate a certain scenario of a restart for the
  # current docker compose project, depending on what DevOps-related files were updated during any further 'source update' call
  source restart watcher run

  # Run post-getup hook, if exists
  if [[ -f ~/.indi/post-getup ]]; then
    source ~/.indi/post-getup
  fi
}

# shellcheck disable=SC2120
mysql_import() {

  # If docker is installed - call mysql_import function within the wrapper-container environment and return 0
  if command -v docker >/dev/null 2>&1; then
    docker compose exec -it -e TERM="$TERM" wrapper bash -ic "source maintain/functions.sh; mysql_import"
    return 0
  fi

  # Print newline
  echo

  # Make sure execution stops on any error
  set -eu -o pipefail

  # Path to a file to be created once import is done
  local done=/var/lib/mysql/import.done;

  # If import is done - do nothing
  if [[ -f "$done" ]]; then return 0; fi

  # Collect missing dump files
  missing=""
  for dump in $MYSQL_DUMP; do
    local="data/$dump"
    shopt -s nullglob; chunks=("$local"[0-9][0-9]); shopt -u nullglob
    if [[ ! -f "$local" && ${#chunks[@]} = "0" ]]; then
      if [[ "$missing" = "" ]]; then
        missing="$dump"
      else
        missing="$missing $dump"
      fi
    fi
  done

  # If no expected dump files are missing
  if [[ "$missing" = "" ]]; then

    # Import the dump files that we have
    for file in $MYSQL_DUMP; do
      import_possibly_chunked_dump "$file"
    done

    # Run maxwell-specific sql
    prepare_maxwell

  # Else if at least one dump file is missing
  else

    # Use GH_TOKEN_CUSTOM_RW as GH_TOKEN
    export GH_TOKEN="$(get_env "GH_TOKEN_CUSTOM_RW")"

    # Load list of available releases for current repo. If no releases - load ones for parent repo, if current repo
    # was forked or generated. But anyway, $init_repo and $init_release variables will be set up to clarify where to
    # download asset from, and it will refer to either current repo, or parent repo for cases when current repo
    # has no releases so far, which might be true if it's a very first time of the instance getting up and running
    # for the current repo
    if (( ${#releaseQty[@]} == 0 )); then
      load_releases "$(get_current_repo)" "init"
    fi

    # If release was detected to init from - do it
    if [[ ! -z "${init_repo:-}" ]]; then
      choice_title=$(get_release_title $init_release)
      echo -e "SELECTED VERSION: ${g}${choice_title}${d}"
      echo -e "         Release: ${g}$init_repo:$init_release${d}"
      if [[ "$init_repo" = "$(get_current_repo)" ]]; then
        echo -e "            Repo: ${g}current${d} / ${gray}parent${d}"
      else
        echo -e "            Repo: ${gray}current${d} / ${g}parent${d}"
      fi
      echo
      restore_dump "$init_release" "$init_repo" "init"

    # Else temporary switch to system token to download and import system dump
    else
      echo "None of SQL dump file(s) are found, assuming blank Indi Engine instance setup"
      export GH_TOKEN="$(get_env "GH_TOKEN_SYSTEM_RO")"
      download_possibly_chunked_file "indi-engine/system" "default" "dump.sql.gz"
      import_possibly_chunked_dump "dump.sql.gz"

      # Run maxwell-specific sql
      prepare_maxwell
    fi

    # Restore GH_TOKEN back, as it might have been spoofed with
    # GH_TOKEN_PARENT_RO by (load_releases .. "init") call above
    # or with
    # GH_TOKEN_SYSTEM_RO in case of blank Indi Engine instance setup
    export GH_TOKEN="$(get_env "GH_TOKEN_CUSTOM_RW")"
  fi

  # Print newline
  echo

  # Create a file indicating that import is done
  touch "$done"
}

# Run maxwell-specific sql
prepare_maxwell() {
  export MYSQL_PWD=$MYSQL_PASSWORD
  mysql -h mysql -u root -e "GRANT ALL ON "'`maxwell`'".* TO '$MYSQL_USER'@'%';"
  mysql -h mysql -u root -e "GRANT SELECT, REPLICATION SLAVE, REPLICATION CLIENT ON *.* TO '$MYSQL_USER'@'%';"
  unset MYSQL_PWD
}

# Get URL of current instance
get_self_href() {
  echo "$(get_self_prot)://$(get_self_host)"
}

# Get current instance's protocol
get_self_prot() {

  # Setup protocol to be 'http', by default
  prot="http"

  # Pick LETS_ENCRYPT_DOMAIN from .env file, if possible
  LETS_ENCRYPT_DOMAIN=$(grep "^LETS_ENCRYPT_DOMAIN=" .env | cut -d '=' -f 2-)

  # If SSL cert was expected to be created and was really created - setup protocol to be 'https'
  if [[ ! -z "$LETS_ENCRYPT_DOMAIN" ]]; then
    if docker compose exec apache certbot certificates | grep -q "Domains: $LETS_ENCRYPT_DOMAIN"; then
      prot="https"
    fi
  fi

  # Print protocol
  echo $prot
}

# Get current instance's host
get_self_host() {

  # Pick LETS_ENCRYPT_DOMAIN and APP_ENV from .env file
  LETS_ENCRYPT_DOMAIN=$(grep "^LETS_ENCRYPT_DOMAIN=" .env | cut -d '=' -f 2-)
  APP_ENV=$(grep "^APP_ENV=" .env | cut -d '=' -f 2-)

  # Detect host
  if [[ ! -z $LETS_ENCRYPT_DOMAIN ]]; then
    host=${LETS_ENCRYPT_DOMAIN%% *}
  elif [[ $APP_ENV == "production" || $APP_ENV == "staging" ]]; then
    host=$(curl -sS --fail-with-body http://ipecho.net/plain)
  else
    host="localhost"
  fi

  # Print host
  echo $host
}

# Clear last X lines
clear_last_lines() {
  for ((i = 0; i < $1; i++)); do tput cuu1 && tput el; done
}

# Ask user for some value to be inputted
read_text() {
  local tip="${1:-}"
  local env_name="${2:-$ENV_NAME}"
  local req=${3:-$REQ}
  local _set_env=${4:-false}
  [[ $tip == true ]] && tip=$(get_env_tip "$env_name")
  echo -e "${gray}${tip}${d}" && echo -n "$env_name=" && while :; do
    read -r INPUT_VALUE
    if [[ $req == true && -z "$INPUT_VALUE" ]]; then
      echo -n "$env_name="
    else
      [[ "$_set_env" == true ]] && set_env "$env_name" "$INPUT_VALUE"
      break
    fi
  done
}

# Ask user for some value to be chosen among pre-defined values for an .env-variable
# Variables choice_idx and choice_txt are globally set after this function is called
read_choice_env() {

    # Variables
    IFS=',' read -r -a choices <<< "$2"

    # Print tip
    echo -e "${gray}${1}${d}"

    # Print variable name with currently selected value
    echo "$ENV_NAME=${choices[0]}"

    # Print instruction on how to use keyboard keys
    echo "" && echo "» Use the up and down arrow keys to navigate and press Enter to select."

    # Force user to choose one among possible values
    read_choice

    # Set variable according to selection
    INPUT_VALUE="$choice_txt"

    # Clear menu
    clear_last_lines $((${#choices[@]}+2))
}

# Function to ask the user to make a choice based on an array of options
# Variables choice_idx and choice_txt are globally set after this function is called
read_choice_custom() {

    # Arguments
    tip="$1" && IFS=',' read -r -a choices <<< "$2"

    # Print tip
    echo -e $tip

    # Force user to choose one among the options
    read_choice

    # Clear only the lines containing options
    clear_last_lines $((${#choices[@]} + 1))
}

# Ask user to make a choice based on choices-array, which must be defined before calling this function
# Once user do some choice, it's 0-based index is written to the choice_idx-variable which can be evaluated
# right after this function is completed
read_choice() {

  # Variables
  local indent="" && [[ ! -z ${ENV_NAME:-} ]] && indent="  "
  local now_choice=${1:-0}
  local was_choice=0
  local key="none"

  # Print choices
  for i in "${!choices[@]}"; do
    if [ $i -eq $now_choice ]; then echo -n "$indent(•)"; else echo -n "$indent( )"; fi && echo " ${choices[$i]}"
  done

  # Force user to make a choice
  while [[ ! -z $key ]]; do

    # Remember selection
    was_choice=$now_choice

    # Capture user input (up/down/enter keys)
    read -n 1 -s key && case "$key" in
      'B') ((now_choice < ${#choices[@]} - 1)) && ((now_choice++)) || true ;;  # Down arrow key
      'A') ((now_choice > 0)) && ((now_choice--)) || true ;;                   # Up arrow key
    esac

    # Move choice
    move_choice $was_choice $now_choice ${#choices[@]}
  done

  # Setup variable to be picked from outside
  choice_idx=$now_choice
  choice_txt=${choices[$choice_idx]}
}

# Setup auxiliary variables
setup_auxiliary_variables() {

  # Delimiter to distinguish between tag name and backup date
  # within backup name i.e. 'D4 · 01 Dec 24, 22:11'
  delim=" · "

  # Get repo 'owner/name'
  repo=$(get_current_repo)

  # Get the backup prefix as a first char of APP_ENV plus first char of backup period
  # Examples:
  # - pd1 => Production instance's daily backup for 1 day ago (i.e. yesterday)
  # - dw2 => Development instance's weekly backup for 2 weeks ago
  # - sd0 => Staging instance's daily backup for today early morning
  tag_prefix=${APP_ENV:0:1}${rotation_period_name:0:1}
}

# Get current repo
get_current_repo() {

  # Get line containing [remote "origin"]...github.com/<repo>
  origin=$(cat .git/config | tr -d '\n' | grep -Pzo '\[remote "origin"].+?url\s*=\s*https?://([a-zA-Z0-9_\-]+@)?github\.com/([a-zA-Z0-9_\-]+/[a-zA-Z0-9_.\-]+)(\.git)?\w' | tr -d '\0')

  # Get repo name
  repo="${origin##*github.com/}"

  # Trim trailing '.git' from repo name as this is unsupported by GitHub CLI
  echo "${repo%.git}"
}

# Setup values for is_rotated_backup and rotated_qty variables
check_rotated_backup() {

  # Get info about backups rotation
  BACKUPS="$(get_env "BACKUPS")"

  # Prepare array of [period => rotated qty] pairs out of $BACKUPS .env-variable
  declare -gA qty=() && for pair in $BACKUPS; do qty["${pair%%=*}"]="${pair#*=}"; done

  # Setup is_rotated_backup flag
  [[ -v qty["$rotation_period_name"] ]] && is_rotated_backup=1 || is_rotated_backup=0

  # Quantity of backups
  (( is_rotated_backup )) && rotated_qty=${qty["$rotation_period_name"]} && (( rotated_qty > 0 )) || rotated_qty=0

  # If it's a rotated backup having 0 as rotation qty - this means backups of such a period are disabled
  if (( is_rotated_backup && rotated_qty == 0 )); then
    exit 0
  fi
}

# Prepare array of [tag name => backup name] pairs
load_releases() {

  # Arguments
  local repo=$1
  local step=${2:-}
  local list

  # Declare array.
  # IMPORTANT: will be overwritten by any further calls of load_releases() function
  declare -gA releases=()

  # If $GH_TOKEN variable is set - work via via GitHub CLI
  if [[ ! -z "${GH_TOKEN:-}" ]]; then

    # Get current repo releases list via GitHub CLI
    list=$(gh release ls --json name,tagName -R "$repo" --jq '.[] | "\(.tagName)=\(.name)"')

    # Convert into array of [release tag => release name] pairs
    if [[ ${#list} > 0 ]]; then
      while IFS="=" read -r tag name; do
        releases["$tag"]="$name"
      done < <(echo "$list")
    fi

  # Else work via via GitHub API
  else

    # Get current repo releases list
    list=$(curl -s "https://api.github.com/repos/$repo/releases" | jq -r '.[] | "\(.tag_name)=\(.name)=\(.published_at)"')

    # Convert into array of [release tag => release name] pairs
    if [[ ${#list} > 0 ]]; then
      local latest_tag=$(get_latest_release "$list")
      while IFS="=" read -r tag_name name published_at; do
        releases["$tag_name"]="$(format_release_line "$name" "$latest_tag" "$tag_name" "$published_at")"
      done < <(echo "$list")
    fi
  fi

  # Remember releases quantity for a repo
  releaseQty["$repo"]=${#releases[@]}

  # If at least one release exist for the current repo
  if (( ${#releases[@]} > 0 )); then

    # Prepare sorted_tags 0-indexed array from releases associative array
    # We do that this way because the order of keys in associative array in Bash - is NOT guaranteed
    # Sorting is done by env code index ascending and then the release visible date descending
    # Also, $default_release_tag variable is indirectly set by this function call
    sort_releases

    # If we're at the init-step - setup $init_repo and $init_release variables
    # to clarify where init-critical assets should be downloaded from
    if [[ $step == "init" ]]; then
      init_repo="$repo"
      init_release="$default_release_tag"
    fi

  # Else if there are no releases for the current repo, but we're at the init-step and no parent repo was detected so far
  elif [[ $step == "init" && -z "${parent_repo:-}" ]]; then

    # Try to detect parent repo, if:
    #  - current repo was forked or generated from that parent repo
    #  - parent repo is a public one, or is a private one but accessible with current GH_TOKEN_CUSTOM_RW
    parent_repo=$(get_parent_repo "$repo")

    # If parent repo detected, it means current repo was recently forked or generated from it,
    # and right now it's a very first time when the whole 'docker compose'-based Indi Engine
    # instance is getting up and running for the current repo, so try to load releases of parent repo
    if [[ $parent_repo != "null" ]]; then

      # Set up GH_TOKEN_PARENT_RO to be further accessible
      export GH_TOKEN_PARENT_RO="$(get_env "GH_TOKEN_PARENT_RO")"

      # If GH_TOKEN_PARENT_RO is given - use it for loading releases of parent repo
      if [[ ! -z "${GH_TOKEN_PARENT_RO:-}" ]]; then export GH_TOKEN="${GH_TOKEN_PARENT_RO:-}"; fi

      # Load releases for parent repo
      load_releases "$parent_repo" "init"
    fi
  fi
}

# Prepare sorted_tags 0-indexed array from releases associative array
# We do that this way because the order of keys in associative array in Bash - is NOT guaranteed
# Sorting is done by env code index ascending and then the release visible date descending
sort_releases() {

  # Auxiliary variables
  env_codes="psd"
  rotation_period_codes="hdwmcb"
  unknown_sortable_date="000000000000"
  unknown_env_code_index="9"

  # Define an array to hold array release tags in the right order
  declare -g sorted_tags=()

  # Regex to match the tag of a rotated release prefixed with
  # an env_code of an instance from where a specific release
  # was uploaded into github
  regex="^[$env_codes][$rotation_period_codes][0-9]+$"

  # Parse the releases and assign priorities based on date
  for tag in "${!releases[@]}"; do

    # Default values
    sortable_date=$unknown_sortable_date
    env_code_index=$unknown_env_code_index

    # Match the tagName to the regex pattern
    if [[ "$tag" =~ $regex ]]; then

      # Extract the first character of a tag name
      env_code="${tag:0:1}"

      # Extract the release title (e.g., "Production · D3 · 13 Dec 24, 01:00")
      title="${releases[$tag]}"

      # Extract the date part from the title (e.g., "13 Dec 24, 01:00") and remove comma
      visible_date=${title##*" · "}
      visible_date=$(echo $visible_date | sed 's/\([0-9]\{2\}:[0-9]\{2\}\).*/\1/')
      visible_date="${visible_date/,/}"

      # Convert the date to a sortable format (YYYYMMDDHHMM)
      sortable_date=$(date -d"$visible_date" +"%Y%m%d%H%M" 2>/dev/null)

      # If date parsing failed,
      if [[ -z "$sortable_date" ]]; then sortable_date=$unknown_sortable_date; fi

      # Get index
      env_code_index="${env_codes%%$env_code*}" && env_code_index=${#env_code_index}
    fi

    # Convert the tag into a sortable expression and append to array
    sorted_tags+=("$env_code_index,$sortable_date,$tag")
  done

  # Sort the releases by index of env_code among env_codes ascending, and then by sortable_date
  IFS=$'\n' sorted_tags=($(sort -t',' -k1,1 -k1,1r -k2,2nr <<< "${sorted_tags[*]}")) && unset IFS

  # Remove env_code and sortable_date so keep only the tags themselves
  for idx in "${!sorted_tags[@]}"; do
    IFS=',' read -r _ _ tag <<< "${sorted_tags[$idx]}" && sorted_tags[$idx]=$tag
  done

  # Setup default release
  default_restore_choice
}

# Set up global default_release_idx and default_release_tag variables that will identify the release to be:
#
# - restored during the initial setup/deploy of your 'docker compose'-based Indi Engine instance
# - selected as a default choice when 'source restore' command is executed so the available restore choices are shown
#
# Logic:
#
# 1.We do already have global sorted_tags array, where all backups we have on github do appear in maximum 4 groups
#   in the following order: production tags, staging tags, development tags and any other tags. In first 3 groups
#   tags are sorted by the dates mentioned in release names, e.g. '13 Dec 24, 01:00' converted to sortable
#   format, in descending order. So the overall sorting logic is that:
#     1.production backups, if any, are at the top of the list with most recent one at the very top globally
#     2.staging backups, if any, with the most recent staging backup at the very top among such kind of backups
#     3.development backups, if any, with the most recent development backup at the very top among such kind of backups
#     4.any other backups, if any, with the non-guaranteed order among them
# 2.Priority
#   1.If we have >= 1 production backups - pick 1st, so it will be the most recent among the production ones
#   2.Else if we have >= 1 backups made by this instance i.e./or instance having same APP_ENV - pick 1st
#   3.Else pick global first in sorted_tags, whatever it is
default_restore_choice() {

  # Initial choice
  default_release_idx=-1
  default_release_tag=""

  # Current application environment code, i.e. 'p' for 'production', etc
  local our_env_code=${APP_ENV:0:1}

  # Iterate through sorted tags
  for idx in "${!sorted_tags[@]}"; do

    # Get iterated tag
    tag=${sorted_tags[$idx]}
    tag_env_code=${tag:0:1}

    # Stop iterating to prevent further changes of the defaults set above when
    # iterated tag indicates a production-release, or release uploaded by the current
    # instance or any other instance having same APP_ENV as the current instance
    if [[ $tag_env_code == "p" || $tag_env_code == $our_env_code ]]; then
      # Set default release tag and idx as iterated ones
      default_release_idx=$idx
      default_release_tag=$tag
      break
    fi
  done

  # If iteration worked till the end but no release was picked so far - pick the first among what we have
  if (( default_release_idx == -1 )); then
    default_release_idx=0
    default_release_tag=${sorted_tags[0]}
  fi
}

# Check whether release exists under given tag, and if yes - setup backup_name variable
# Note: backup = release, but term 'release' is used when we communicate to github,
# and at the same time term 'backup' - is to indicate the purpose behind usage of releases
has_release() {
  if [[ -v releases["$1"] ]]; then
    backup_name=${releases["$1"]}
  else
    backup_name=""
    return 1
  fi
}

# Delete release from github, if exists. Deletion is only applied to the backup
# that is the oldest among the ones having same period, e.g. oldest daily backup, oldest weekly backup, etc
delete_release() {

  # If backup really exists under given tag
  if has_release $1; then

    # Print that
    echo -n "exists"

    # Delete it with it's tag
    delete=$(gh release delete "$1" -y --cleanup-tag)

    # Print that
    echo ", deleted"$delete

  # Else print that backup does not exist so far
  else
    echo "does not exist"
  fi
}

# Move release from one tag to another
retag_release() {

  # If backup really exists
  if has_release $1; then

    # Print that
    echo -n "exists"

    # If backup name has middle dot, i.e. looks like 'Production · D4 · 01 Dec 24, 22:11'
    # then split name by ' · ' and keep the 3rd chunk only, as the 1st
    # one - i.e. tag name - will now different
    if echo "$backup_name" | grep -q " · " ; then
      backup_name=${backup_name##*" · "}
    fi

    # Update releases array
    point=${2:1} && unset releases["$1"] && releases["$2"]="${APP_ENV^}${delim}${point^^}${delim}${backup_name}"

    # Re-tag the currently iterated backup from $this_tag to $prev_tag,
    # so that it is kept as is, but now appears older than it was before
    # and become one step closer to the point where it will become the
    # oldest so it will be removed from github
    edit=$(gh release edit "$1" --tag="$2" --title="${releases["$2"]}")

    # Print that
    echo -n ", moved to $2"

    # If $edit is NOT an URL of the tag - print it
    [[ ! "$edit" =~ ^https?:// ]] && echo $edit;

    # Update the hash that $prev_tag is pointing to
    set_tag_hash "$2" "$(get_tag_hash $1)"

  # Else
  else
    echo "does not exist"
  fi
}

# Get hash of a given remote tag
get_tag_hash() {
  gh api repos/$repo/git/ref/tags/$1 --jq .object.sha
}

# Re-assign given tag into a new commit hash
set_tag_hash() {

  # Do set and get result
  result=$(git tag "$1" "$2" --force)$(git push "https://$GH_TOKEN_CUSTOM_RW@github.com/$repo.git" "$1" --force 2>&1)

  # Print result
  if echo "$result" | grep -q "forced update" ; then
    echo ", $1 => ${2:0:7}"
  else
    echo ", $1 re-assign: $result"
  fi
}

# Prepare and backup current database dump and file uploads into github under the given tag
backup() {

  # Arguments
  rotation_period_name=${1:-custom}

  # Prepare $tag variable containing the right tag name for the backup.
  # If $rotation_period_name is known among the ones listed in $BACKUPS in .env file,
  # then tag name is based on $APP_ENV, $rotation_period_name and index within rotation queue,
  # else tag name is used as is, so any backup already existing under that tag will be overwritten
  prepare_backup_tag "$rotation_period_name"

  # Re-assign given tag to the latest commit
  set_tag_hash "$tag" "$(get_head)" && echo ""

  # Backup uploads and dump
  backup_uploads "$tag"
  backup_dump "$tag"
}

# Backup previously prepared database dump and file uploads into github under the given tag
backup_prepared_assets() {

  # Arguments
  rotation_period_name=${1:-custom}
  dir=${2:-data}

  # Prepare $tag variable containing the right tag name for the backup.
  # If $rotation_period_name is known among the ones listed in $BACKUPS in .env file,
  # then tag name is based on $APP_ENV, $rotation_period_name and index within rotation queue,
  # else tag name is used as is, so any backup already existing under that tag will be overwritten on github
  prepare_backup_tag "$rotation_period_name" "» "

  # Re-assign given tag to the latest commit
  set_tag_hash "$tag" "$(get_head)" && echo "» ---"

  # Prepare chunks list and qty
  local_chunks=$(ls -1 "$dir/uploads".z* 2> /dev/null | sort -V)
  local_chunks_qty=$(echo "$local_chunks" | wc -w)

  # If there a more than 1 chunk
  if (( local_chunks_qty > 1 )); then

    # Upload one by one
    echo "» Uploading $dir/uploads.zip ($local_chunks_qty chunks):"
    for local_chunk in $local_chunks; do
      upload_asset "$local_chunk" "$tag" "» - "
    done

  # Else download the single file, overwriting the existing one, if any
  else
    upload_asset "$dir/uploads.zip" "$tag" "» "
  fi

  # Backup dump
  upload_asset "$dir/$MYSQL_DUMP" "$tag" "» "
}

# Backup current database dump on github into given release assets of current repo
backup_dump() {

  # Arguments
  release=$1

  # Prepare dump
  source maintain/dump-prepare.sh "" && asset="$dump"

  # Upload possibly chunked dump.sql.gz to github using glob pattern dump.sql.gz*
  upload_possibly_chunked_file $release "$asset*"
}

# Load whitespace-separated list of names of assets that are chunks
load_remote_chunk_list() {

  # Arguments
  local repo="$1"
  local release="$2"
  local pattern="$3"

  # Load asset names
  if [[ ! -z "${GH_TOKEN:-}" ]]; then
    local list=$(gh release view "$release" -R "$repo" --json assets --jq '.assets[].name | select(test("'$pattern'"))')
  else
    local list=$(curl -s "https://api.github.com/repos/$repo/releases/tags/$release" | jq -r '.assets[].name | select(test("'$pattern'"))')
  fi

  # Replace newlines with spaces
  echo "${list//$'\n'/ }"
}

# Backup current uploads on github into given release assets of current repo
backup_uploads() {

  # Arguments
  release=$1

  # Prepare uploads
  source maintain/uploads-prepare.sh "" && asset="$uploads"

  # Upload possibly chunked upload.zip to github using glob pattern uploads.z*
  upload_possibly_chunked_file $release "${asset%.zip}.z*"
}

# Upload possibly chunked file to github, based on glob pattern
upload_possibly_chunked_file() {

  # Arguments
  local release="$1"
  local pattern="$2"

  # Get current repo
  local repo="$(get_current_repo)"

  # Get remote chunks
  local remote_chunks=$(load_remote_chunk_list "$repo" "$release" ${pattern##*/})

  # For each local chunk - upload on github
  local local_chunks=$(ls -1 $pattern 2> /dev/null | sort -V)
  local local_chunks_qty=$(echo "$local_chunks" | wc -w)

  # If there a more than 1 local chunk
  if (( local_chunks_qty > 1 )); then

    # Upload one by one
    echo "Uploading chunks:"
    for local_chunk in $local_chunks; do
      upload_asset "$local_chunk" "$release" "» "
    done

    # Replace newlines with spaces in list of local chunks
    local_chunks="${local_chunks//$'\n'/ }"

  # Else upload the single file, overwriting the existing one, if any
  else
    upload_asset "$local_chunks" "$release"
  fi

  # Delete obsolete remote assets, if any remaining on github
  local obsolete="0"
  for remote_chunk in $remote_chunks; do
    if [[ ! " $local_chunks " =~ [[:space:]]$(dirname "$pattern")/$remote_chunk[[:space:]] ]]; then
      if [[ $obsolete = "0" ]]; then
        echo "Deleting obsolete remote chunk(s):" && obsolete="1"
      fi
      echo -n "» " && delete_asset "$remote_chunk" "$release"
    fi
  done

  # Print newline
  echo ""
}

# Delete asset within a release
delete_asset() {

  # Arguments
  asset=$1
  release=$2

  # Do delete
  if [[ ! -z "$GH_TOKEN_CUSTOM_RW" ]]; then
    gh release delete-asset -y "$release" "$asset"
  else
    echo "Not yet supported"
    exit 1
  fi
}

# Upload given file on github as an asset in given release of the current repo
upload_asset() {

  # Arguments
  asset=$1
  release=$2
  p=${3:-}

  # Shortcuts
  local hdr1="Authorization: Bearer ${GH_TOKEN_CUSTOM_RW}"
  local hdr2="Content-Type: application/octet-stream"
  local hdr3="Accept: application/vnd.github+json"
  local out="var/tmp/chunks.json"
  local repo=$(get_current_repo)

  # Print where we are
  msg="${p}Uploading $asset into '$repo:$release'..."; echo $msg

  # Get release and assets info
  gh release view "$release" --json databaseId,assets > $out

  # Get releaseId and asset apiUrl usable for curl requests
  releaseId=$(jq '.databaseId' $out); assetUrl=$(jq -r '.assets[] | select(.name == "'${asset##*/}'") | .apiUrl' $out)

  # If asset already exists
  if [[ "$assetUrl" != "" ]]; then

    # Delete it
    set +e; curl -fL -X DELETE -H "$hdr1" -H "$hdr3" "$assetUrl"; exit_code=$?; set -e

    # If deletion failed - return error
    if [[ exit_code -ne 0 ]]; then return 1; fi
  fi

  # Prepare url
  local url="https://uploads.github.com/repos/${repo}/releases/${releaseId}/assets?name=${asset##*/}"

  # Disable exit on error to allow curl to print error (if occurred) instead of silent exit
  # Run curl with progress bar only
  # Enable exit on error back
  set +e
  curl -fL -X PUT -H "$hdr1" -H "$hdr2" --upload-file "$asset" -o /dev/null -# "$url"; exit_code=$?;
  set -e

  # If curl failed - return error, else clear last 2 lines
  if [[ exit_code -ne 0 ]]; then return 1; else clear_last_lines 2; fi

  # Print done
  echo "$msg Done"
}

# Restore database state from the dump.sql.gz of a given release tag
# If release tag is not given - existing data/dump.sql.gz file will be used
# shellcheck disable=SC2120
restore_dump() {

  # Arguments
  local release="${1:-}"
  local repo="${2:-$(get_current_repo)}"
  local step="${3:-}"

  # If $release arg is given - download each (possibly chunked) dump file
  if [[ "$release" != "" ]]; then
    for file in $MYSQL_DUMP; do
      download_possibly_chunked_file "$repo" "$release" "$file"
    done
  fi

  # Restore downloaded possibly chunked dump
  restore_dump_from_local "data" "" "$step"
}

# Restore database from local possibly chunked dump, located in a given directory
restore_dump_from_local() {

  # Arguments
  local dir="${1:-data}"
  local prepend="${2:-}"
  local step="${3:-}"

  # Global variables needed by (stop|start)_maxwell_and_closetab_if_need functions
  declare -g closetab=false
  declare -g maxwell=false

  # Shortcuts
  fn1='stop_maxwell_and_closetab_if_need'
  fn2='reset_mysql'
  fn3='prepare_maxwell'
  fn4='start_maxwell_and_closetab_if_need'

  # Stop maxwell and/or closetab php processes if any running
  # Shut down mysql server, clean it's data/ dir and start back
  if [[ $step != "init" ]]; then
    if [[ $prepend != "" ]]; then
      $fn1 2>&1 | prepend "$prepend"; $fn2 2>&1 | prepend "$prepend"
    else
      $fn1; $fn2
    fi
  fi

  # Import each (possibly chunked) dump
  [[ "$prepend" != "" ]] && echo -ne "${gray}"
  for file in $MYSQL_DUMP; do
    import_possibly_chunked_dump "$file" "$dir" "$prepend"
  done
  [[ "$prepend" != "" ]] && echo -ne "${d}"

  # Run maxwell-specific sql
  if [[ "$prepend" != "" ]]; then $fn3 2>&1 | prepend "» "; else $fn3; fi

  # If maxwell and/or closetab php processes were running - enable back
  if [[ $step != "init" ]]; then
    if [[ "$prepend" != "" ]]; then $fn4 2>&1 | prepend "» "; else $fn4; fi
  fi

  # Create a file indicating that import is done
  touch "/var/lib/mysql/import.done"
}

# Import dump with a given filename, or count
import_possibly_chunked_dump() {

  # Arguments
  dump="$1"
  dir="${2:-data}"
  prepend="${3:-}"

  # Shortcuts
  local path="$dir/$dump"
  local msg="${prepend}Importing $dump"
  local run="mysql -h mysql -u root $MYSQL_DATABASE"

  # Prevent warning
  export MYSQL_PWD=$MYSQL_PASSWORD

  # If dump file exists in data/ directory - import
  if [[ -f "$path" ]]; then

    # If dump is gzipped - pipe to gunzip
    if [[ "${dump##*.}" = "gz" ]]; then
      pv --name "$msg" -pert "$path" | gunzip | $run
    else
      pv --name "$msg" -pert "$path" | $run
    fi

  # Else
  else

    # Get local chunks array, if any
    shopt -s nullglob; chunks=("$path"[0-9][0-9]); shopt -u nullglob

    # If chunks detected - import
    if [[ ${#chunks[@]} -gt 0 ]]; then

      # If dump is gzipped - pipe to gunzip
      if [[ "${dump##*.}" = "gz" ]]; then
        pv --name "$msg" -pert "${path}"[0-9][0-9] | gunzip | $run;
      else
        pv --name "$msg" -pert "${path}"[0-9][0-9] | $run;
      fi
    fi
  fi

  # Unset back
  unset MYSQL_PWD
}

# Download possibly chunked file from github, based on glob pattern
download_possibly_chunked_file() {

  # Arguments
  local repo="$1"
  local release="$2"
  local file="$3"
  local dir="${4:-data}"
  local count_missing=${5:-false}

  # Prepare glob pattern to find chunks, if any
  if [[ "$file" =~ \.zip$ ]]; then
    local pattern="${file%.zip}.z*"
  else
    local pattern="$file*"
  fi

  # Load lists of remote and local chunks of $file
  local local_chunks=$(ls -1 "$dir/"$pattern 2> /dev/null | sort -V | tr '\n' ' ') || true

  # If $release is given
  if [[ -n "$release" ]]; then

    # Load list of remote chunks of $file
    local remote_chunks=$(load_remote_chunk_list "$repo" "$release" "$pattern")
    local remote_chunks_qty=$(echo "$remote_chunks" | wc -w)

    # If there a more than 1 chunk
    if (( remote_chunks_qty > 1 )); then

      # Download one by one
      echo "Downloading $file from $repo:$release into data/ dir ($remote_chunks_qty chunks):"
      for remote_chunk in $remote_chunks; do
        gh_download "$repo" "$release" "$remote_chunk" "$dir"
        echo "» Downloading $remote_chunk... Done"
      done

    # Else download the single file, overwriting the existing one, if any
    else
      local msg="Downloading $file from $repo:$release into data/ dir..." && echo "$msg"
      gh_download "$repo" "$release" "$file" "$dir"
      if [[ $- == *i* || -n "${FLASK_APP:-}" ]]; then clear_last_lines 1; fi
      echo "$msg Done"
    fi

    # Delete obsolete local chunks, if any
    local obsolete="0"
    for local_chunk in $local_chunks; do
      if [[ ! " $remote_chunks " =~ [[:space:]]${local_chunk##*/}[[:space:]] ]]; then
        if [[ $obsolete = "0" ]]; then
          echo "Deleting obsolete local chunk(s):" && obsolete="1"
        fi
        echo -n "» " && echo "$local_chunk" && rm "$local_chunk"
      fi
    done
  fi

  # Get file path and chunks paths, if any
  local="$dir/$file"; shopt -s nullglob; chunks=("$local"[0-9][0-9]); shopt -u nullglob

  # If neither file exists nor chunks - increment missing files counter
  if [[ ! -f "$local" && ${#chunks[@]} -eq 0 && $count_missing = true ]]; then
      missing=$((missing + 1))
  fi
}

# Stop maxwell and/or closetab php processes if any running
stop_maxwell_and_closetab_if_need() {

  # Get maxwell and closetab status
  maxwell=false;  if curl http://apache/realtime/status/ 2>&1 | grep -q maxwell;  then maxwell=true; fi
  closetab=false; if curl http://apache/realtime/status/ 2>&1 | grep -q closetab; then closetab=true; fi

  # If disable each, if needed
  if [[ $maxwell = true ]];  then curl http://apache/realtime/maxwell/disable/ > /dev/null 2>&1; fi
  if [[ $closetab = true ]]; then curl http://apache/realtime/closetab/        > /dev/null 2>&1; fi
}

# If maxwell and/or closetab php processes were running - enable back
start_maxwell_and_closetab_if_need() {
  if [[ $closetab = true ]]; then curl http://apache/realtime/closetab/ > /dev/null 2>&1; fi
  if [[ $maxwell = true ]];  then curl http://apache/realtime/maxwell/enable/ > /dev/null 2>&1; fi
}

# Shut down mysql server, clean it's data/ dir and start back
reset_mysql() {

  # Shut down mysql
  export MYSQL_PWD=$MYSQL_PASSWORD
  local msg="Shutting down MySQL server..." && echo "$msg"
  mysql -h mysql -u root -e "SHUTDOWN"
  unset MYSQL_PWD

  # Wait until shutdown is really completed
  local timeout=60
  local elapsed=0
  local done="/var/lib/mysql/shutdown.done"
  while :; do
    clear_last_lines 1
    echo "$msg waiting for completion ($elapsed s)"
    sleep 1
    elapsed=$((elapsed + 1))
    if [ -f "$done" ] || [ $elapsed -ge $timeout ]; then break; fi
  done

  # If shutdown file was created by mysql-container custom-entrypoint.sh script
  if [ -f "$done" ]; then

    # It means mysqld process exited gracefully, i.e. shutdown is really completed
    clear_last_lines 1
    echo "$msg Done"

    # Empty mysql_server_data volume
    echo -n "Removing all data from MySQL server..." && rm -rf /var/lib/mysql/* && echo -e " Done"

    # Wait until re-init is really completed
    local msg="Starting up MySQL server back..." && echo "$msg"
    local elapsed=0
    local done="/var/lib/mysql/init.done"
    local initTimeout=60
    local waitTimeout=2
    while :; do
      clear_last_lines 1
      echo "$msg ($elapsed s)"
      sleep 1
      elapsed=$((elapsed + 1))

      # If init maximum time reached - break
      if [ $elapsed -ge $initTimeout ]; then
        echo "MySQL empty init timeout reached, something went wrong :("
        exit 1
      fi

      # If mysql re-init is done: if we need to wait a bit more - do wait, else break
      if [ -f "$done" ]; then
        if [[ "$waitTimeout" != "0" ]]; then waitTimeout=$((waitTimeout - 1)); else break; fi
      fi
    done
    clear_last_lines 1
    echo "$msg Done"

  # Else if shutdown is stuck somewhere - print error message and exit
  else
    echo "MySQL server shutdown timeout reached, something went wrong :("
    exit 1
  fi
}

# Restore state of custom/data/upload dir from the uploads.zip of a given release tag
# If release tag is not given - existing data/uploads.zip file will be used
restore_uploads() {

  # Arguments
  local release="${1:-}"
  local repo="${2:-$(get_current_repo)}"

  # Name of the backup file
  local file="uploads.zip"

  # Download possibly chunked uploads.zip
  download_possibly_chunked_file "$repo" "$release" "$file"

  # Extract
  unzip_file "data/$file" "custom/data/upload" "www-data:www-data"
}

# Set given $string at given position as $column and $lines_up relative to the current line
set_string_at() {

  # Arguments
  local string=$1
  local column=$2
  local lines_up=$3

  # 1.Save current cursor position
  # 2.Move cursor to the spoofing position
  # 3.Write the new symbol
  # 4.Restore the original cursor position
  echo -ne "\033[s"
  echo -ne "\033[${lines_up}A\033[${column}C"
  echo -n "$string"
  echo -ne "\033[u"
}

# Move visual indication of selected choice from previous choice to current choice
move_choice() {

  # Arguments
  local was=$1
  local now=$2
  local qty=$3
  local col=${4:-1}
  local val=""

  # Add the length of choices_indent only if it is defined (non-empty)
  if [[ -n "${indent:-}" ]]; then
    ((col += ${#indent}))
  fi

  # Move choice
  if [[ "$now" != "$was" ]]; then

    # Visually move choice
    set_string_at " " "$col" "$((qty-was))"
    set_string_at "•" "$col" "$((qty-now))"

    # If $ENV_NAME variable is set - it means we're choosing a value for some .env-variable
    if [[ ! -z ${ENV_NAME:-} ]]; then

      # Prepare the line to be used for re-renderiing the existing line where 'SOME_NAME=SOME_VALUE' is printed
      line="$ENV_NAME="$(printf "%-*s" $(longest_choice_length) "${choices[$now]}")

      # Do re-render
      set_string_at "$line" "-1" $((${#choices[@]}+3))
    fi
  fi
}

# Get length of longest choice
# Currently this is used to pad the'SOME_NAME=SOME_VALUE' string with white spaces
# in the terminal screen when newly selected SOME_VALUE is shorter than previously selected one
longest_choice_length() {

  # Initialize variables to track the max length and corresponding item
  local max_length=0
  local max_item=""

  # Iterate through the array
  for item in "${choices[@]}"; do

    # Get the length of the current item
    item_length=${#item}

    # Check if it's the longest so far
    if (( item_length > max_length )); then
        max_length=$item_length
        max_item=$item
    fi
  done

  # Print length of longest choice
  echo $max_length
}

# Prepare .env file out of given template file (default .env.dist) with prompting for values where needed
prepare_env() {

  # Input and output files
  local DIST=${1:-".env.dist"}
  local PROD=".env.prod"

  # Clear the output file
  > "$PROD"

  # Reset description and required flag
  local TIP=""
  local REQ=false
  local enum_rex='\[enum=([a-zA-Z0-9_]+(,[a-zA-Z0-9_]+)*)\]'
  local ENUM=false

  # Read the file into an array, preserving lines with spaces
  mapfile -t lines < "$DIST"

  # Process each line in the array
  for line in "${lines[@]}"; do

    # Trim leading/trailing whitespace
    line=$(echo "$line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')

    # If line starts with '#'
    if [[ $line == \#* ]]; then

      # Append it to result file and to TIP variable. Also setup REQ flag and ENUM variable, if need
      TIP+="\n${line}"
      [[ $line == "# [Required"* ]] && REQ=true
      [[ $line =~ $enum_rex ]] && ENUM="${BASH_REMATCH[1]}"
      echo "$line" >> "$PROD"

    # Else if line looks like VARIABLE=...
    elif [[ $line =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then

      # Split by '=' into name and default value
      local ENV_NAME=$(echo "$line" | cut -d '=' -f 1)
      local DEFAULT_VALUE=$(echo "$line" | cut -d '=' -f 2-)

      # Check if a function exists for adjusting TIP and REQ for the ENV_NAME prompt, and if yes - call it
      if declare -f "env_$ENV_NAME" > /dev/null; then
        env_$ENV_NAME
      fi

      # If default value is NOT empty, or value prompting should be skipped
      if [[ ! -z $DEFAULT_VALUE || "$REQ" == "skip" ]]; then

        # Write as is
        echo "$ENV_NAME=$DEFAULT_VALUE" >> "$PROD"

      # Else prompt
      else

        # Ask user to type or choose the value
        if [[ $ENUM == false ]]; then read_text "${TIP}"; else read_choice_env "${TIP}" "$ENUM"; fi

        # Trim leading and trailing whitespaces
        INPUT_VALUE=$(echo "$INPUT_VALUE" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

        # If the trimmed input contains whitespace - enclose in double quotes
        if [[ "$INPUT_VALUE" =~ [[:space:]] ]]; then INPUT_VALUE="\"$INPUT_VALUE\""; fi

        # Write inputted value
        echo "$ENV_NAME=$INPUT_VALUE" >> "$PROD"
      fi

    # Else if line is an empty line or contains only whitespaces
    elif [[ -z $line ]]; then

      # Write that line as well, and reset TIP, REQ and ENUM variables
      echo "" >> "$PROD"
      TIP=""
      REQ=false
      ENUM=false
    fi
  done

  # Rename .env.prod to .env
  mv $PROD .env
}

# Spoof TIP and make GH_TOKEN_CUSTOM_RW required if current repo is private
env_GH_TOKEN_CUSTOM_RW() {

  # If it's a blank cloned Indi Engine repo - skip
  if [[ "$(get_current_repo)" == "indi-engine/newapp" ]]; then
    REQ="skip"
    return 0
  fi

  # Don't put this directly into 'if' to make sure everything will stop on return code 1, if happen
  is_private=$(repo_is_private)

  # If repo is NOT private - skip
  if [[ "$is_private" == false ]]; then
    REQ=skip
    return 0
  fi

  # Else - spoof TIP and make GH_TOKEN_CUSTOM_RW variable to be required
  repo="${g}$(get_current_repo)${gray}"
  href="${g}https://github.com/settings/personal-access-tokens/new${d}${gray}"
  TIP="\n# [Required] Please goto $href,"
  TIP+="\n# create there and input here a fine-grained personal access token with"
  TIP+="\n# read-write access to the Contents of this $repo repo:"
  REQ=true
}

# Spoof TIP and make GH_TOKEN_PARENT_RO required if parent repo exists and is private
env_GH_TOKEN_PARENT_RO() {

  # If it's a blank cloned Indi Engine repo - skip
  if [[ "$(get_current_repo)" == "indi-engine/newapp" ]]; then
    REQ="skip"
    return 0
  fi

  # Get current repo name and visibility
  local current_repo="$(get_current_repo)"
  local current_is_private="$(repo_is_private "$current_repo")"

  # If current repo is private - set GH_TOKEN as otherwise we won't be able to detect parent repo
  if [[ "$current_is_private" = true ]]; then
    export GH_TOKEN="$(grep "^GH_TOKEN_CUSTOM_RW=" .env.prod | cut -d '=' -f 2-)"
  fi

  # Get parent repo, if any exists for current repo
  local parent="$(get_parent_repo "$current_repo" true)"
  local parent_repo="${parent%:*}"
  local child_type="${parent#*:}"

  # If parent repo exists and is not indi-engine/newapp
  if [[ $parent_repo != null && $parent_repo != "indi-engine/newapp" ]]; then

    # Check if parent repo is private
    parent_is_private=$(repo_is_private "$parent_repo")

    # If yes - spoof TIP and make GH_TOKEN_SYSTEM_RO variable to be required
    if [[ "$parent_is_private" = true ]]; then
      TIP="\n# [Required] This repo is ${child_type} from parent ${g}$parent_repo${gray} repo,"
      TIP+="\n# which is private, so this means you were added to the list of collaborators"
      TIP+="\n# by the owner of that parent repo on GitHub. Now please ask owner to create for"
      TIP+="\n# you a fine-grained personal access token with read-only access to the Contents"
      TIP+="\n# of that repo, as otherwise you won't be able to update your instance with"
      TIP+="\n# their fresh database/uploads - vital if your repo has no own backup so far"
      REQ=true
    else
      REQ="skip"
    fi
  else
    REQ="skip"
  fi
}

# Shorten comment for APP_ENV variable
env_APP_ENV() {
  TIP=$(printf "%s" "$TIP" | grep -Pzo '.*if any.' | tr -d '\0')
}

# Skip prompting for LETS_ENCRYPT_DOMAIN if APP_ENV is 'development'
env_LETS_ENCRYPT_DOMAIN() {

  # Load custom token
  local APP_ENV="$(grep "^APP_ENV=" .env.prod | cut -d '=' -f 2-)"

  # If current instance will be a development instance - skip prompt for LETS_ENCRYPT_DOMAIN
  if [[ "$APP_ENV" == "development" ]]; then
    REQ="skip"
  fi
}

# Skip prompting for EMAIL_SENDER_DOMAIN if APP_ENV is 'development'
env_EMAIL_SENDER_DOMAIN() {

  # Get APP_ENV
  local APP_ENV="$(grep "^APP_ENV=" .env.prod | cut -d '=' -f 2-)"

  # If current instance will be a development instance - skip prompt for LETS_ENCRYPT_DOMAIN
  if [[ "$APP_ENV" == "development" ]]; then
    REQ="skip"
  fi
}

# Skip to simplify initial setup. It will be prompted further on attempt to
# 'source restore commit' and 'source update'
env_GIT_COMMIT_NAME() {
  REQ="skip"
}

# Skip to simplify initial setup if neither LETS_ENCRYPT_DOMAIN nor EMAIL_SENDER_DOMAIN is given
env_GIT_COMMIT_EMAIL() {

  # Load configs which require GIT_COMMIT_EMAIL
  local APP_ENV="$(grep "^APP_ENV=" .env.prod | cut -d '=' -f 2-)"
  local LETS_ENCRYPT_DOMAIN="$(grep "^LETS_ENCRYPT_DOMAIN=" .env.prod | cut -d '=' -f 2-)"

  # Ask for GIT_COMMIT_EMAIL only if it's a production instance with $LETS_ENCRYPT_DOMAIN specified
  if [[ "$APP_ENV" != "production" || "$LETS_ENCRYPT_DOMAIN" == "" ]]; then
    REQ="skip"
  fi
}

# Check whether given repo is private
repo_is_private() {

  # Argument #1: repo for which curl request should be executed
  local repo="${1:-$(get_current_repo)}"

  # Shortcut to json query
  local uri="/repos/${repo}"
  local url

  # Get repo info
  set +e
  url="https://api.github.com$uri"
  info=$(curl -sS --fail-with-body "$url" 2>&1); exit_code=$?
  set -e

  # If request failed
  if [[ exit_code -ne 0 ]]; then

    # If request failed because of 404 error - it means repo is private
    if echo "$info" | grep -q "error: 404"; then
      echo true

    # Else if request failed due to some other reason - print error text and return error code 1
    else
      echo "$info" >&2
      return 1
    fi

  # Else it means repo is public
  else
    echo false
  fi
}

# Download file
gh_download() {

  # Arguments
  local repo="$1"
  local release="$2"
  local file="$3"
  local dir=${4:-data}

  # Shortcuts
  local out="$dir/$file"
  local url
  local hdr

  # If $GH_TOKEN is given it might mean the repo is private, and in that case the asset won't be downloadable
  # via ordinary public uri, so we have to retrieve another url from release info and then use that url for downloading
  # the asset.
  #
  # Note: $GH_TOKEN might be given also for public repo, but we anyway can use GitHub CLI and we do that way
  # because otherwise we have to check for whether repo is private which would add unnecessary network overhead
  if [[ ! -z "${GH_TOKEN:-}" ]]; then

    # Get assets info for a given release
    view=$(gh release view "$release" -R "$repo" --json assets)

    # Get needed asset apiUrl usable for wget request
    url="$(echo "$view" | jq -r '.assets[] | select(.name == "'"$file"'") | .apiUrl')"

    # If asset not found - print error and return error code 1
    if [[ "$url" = "" ]]; then
      echo "Asset $file not found in $repo:$release" >&2
      return 1
    fi

    # Set auth header
    hdr="Authorization: Bearer ${GH_TOKEN}"

  # Else
  else

    # Set shortcut for public url
    url="https://github.com/$repo/releases/download/$release/$file"

    # Auth header not needed
    hdr=""
  fi

  # Disable exit on error
  set +e

  # Run wget with progress bar only
  wget --progress=bar --header="$hdr" --header="Accept: application/octet-stream" --show-progress -q -O "$out" "$url"

  # Get exit code
  exit_code=$?

  # If wget failed
  if [[ $exit_code -ne 0 ]]; then

    # Get and print http status
    echo "URL: $url"
    echo $(wget --spider --header="$hdr" --server-response "$url" 2>&1 | grep '^  HTTP' | tail -1)

    # Enable exit on error
    set -e

    # Return wget call's exit code
    return $exit_code

  # Else
  else

    # Enable exit on error
    set -e

    # If we're within an interactive shell - clear last line
    if [[ $- == *i* || -n "${FLASK_APP:-}" ]]; then clear_last_lines 1; fi
  fi
}

# Install GitHub CLI, if not yet installed
ghcli_install() {

  # If GitHub CLI is already installed - return
  if command -v gh &>/dev/null; then
    echo "GitHub CLI is already installed."
    return 0
  fi

  # Print where we're
  echo "Installing GitHub CLI..."

  # Add GPG key
  ghgpg=/usr/share/keyrings/githubcli-archive-keyring.gpg
  if curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | dd of=$ghgpg && chmod go+r $ghgpg; then
    echo "GPG key successfully added."
  else
    echo "Error adding GPG key. Exiting."
    exit 1
  fi

  # Add package info
  echo "deb [arch=$(dpkg --print-architecture) signed-by=$ghgpg] https://cli.github.com/packages stable main" | tee /etc/apt/sources.list.d/github-cli.list > /dev/null

  # Do install
  if apt-get update && apt-get install gh -y; then
    echo "GitHub CLI installed successfully."
    return 0
  else
    echo "Error installing GitHub CLI. Exiting."
    exit 1
  fi
}

# Make sure 'custom/data/upload' dir is created and filled, if does not exist
init_uploads_if_need() {

  # If docker is installed - call mysql_import function within the wrapper-container environment and return 0
  if command -v docker >/dev/null 2>&1; then
    docker compose exec -it -e TERM="$TERM" wrapper bash -ic "source maintain/functions.sh; init_uploads_if_need"
    return 0
  fi

  # Destination dir for Indi Engine uploads
  dest="custom/data/upload"

  # If that dir does not exist
  if [[ ! -d "$dest" ]]; then

    # Print newline
    echo

    # Define file name of the asset, that is needed for creation of the above mentioned dir
    file="uploads.zip"

    # If asset file does not exist locally
    if [[ ! -f "data/$file" ]]; then

      # Use GH_TOKEN_CUSTOM_RW as GH_TOKEN
      export GH_TOKEN="${GH_TOKEN_CUSTOM_RW:-}"

      # Load list of available releases for current repo. If no releases - load ones for parent repo, if current repo
      # was forked or generated. But anyway, $init_repo and $init_release variables will be set up to clarify where to
      # download asset from, and it will refer to either current repo, or parent repo for cases when current repo
      # has no releases so far, which might be true if it's a very first time of the instance getting up and running
      # for the current repo
      load_releases "$(get_current_repo)" "init"

      # Download it from github into data/ dir
      if [[ ! -z "${init_repo:-}" ]]; then
        download_possibly_chunked_file "$init_repo" "$init_release" "$file"
      fi

      # Restore GH_TOKEN back, as it might have been spoofed with GH_TOKEN_PARENT_RO by (load_releases .. "init") call above
      export GH_TOKEN="${GH_TOKEN_CUSTOM_RW:-}"
    fi

    # If asset file does exist locally (due to it was just downloaded or it was already existing locally)
    if [[ -f "data/$file" ]]; then

      # Extract asset with recreating the destination dir and make that dir writable by Indi Engine
      unzip_file "data/$file" "$dest" "www-data:www-data"
      echo

    # Else create empty dir
    else
      mkdir -p "$dest"
    fi
  fi

  # Make uploads dir writable for Indi Engine which might be at least needed
  # if current project have been deployed from a hard copy coming from a disk storage
  # system (e.g. USB Flash Drive) that might not preserve ownership for the stored
  # files and directories, which can lead to that all files and folders copied from
  # such a hard copy into a server will have 'root' as owner, including custom/data/upload
  # dir, so it won't be writable to 'www-data'-user on behalf of which Indi Engine's apache-container is working,
  # so below code is there to solve that problem
  chown -R "www-data:www-data" "$dest"

  # Make executable to allow du-command to be runnable from within apache-container on behalf of www-data user
  chmod +x "$dest/../" "$dest"
}

# If $GH_TOKEN_CUSTOM_RW is set but there are no releases yet in the current repo due to it's
# a forked or generated repo and it's a very first time of the instance getting
# up and running for the current repo - backup current state into a very first own release,
# so that any further deployments won't rely on parent repo releases anymore
make_very_first_release_if_need() {

  # If docker is installed - call mysql_import function within the wrapper-container environment and return 0
  if command -v docker >/dev/null 2>&1; then
    docker compose exec -it -e TERM="$TERM" wrapper bash -ic "source maintain/functions.sh; make_very_first_release_if_need"
    return 0
  fi

  # Get current repo
  current_repo="$(get_current_repo)"

  # Use GH_TOKEN_CUSTOM_RW as GH_TOKEN
  export GH_TOKEN="${GH_TOKEN_CUSTOM_RW:-}"

  # If global releaseQty array is empty, it means load_releases() function was NOT
  # called yet, so call it now as we need to know whether current repo has releases
  if (( ${#releaseQty[@]} == 0 )); then load_releases "$current_repo"; fi

  # If custom token is given
  if [[ -n $GH_TOKEN_CUSTOM_RW ]]; then
    
    # If current repo has no own releases so far - create very first one
    if (( releaseQty["$current_repo"] == 0 )); then
  
      # Print header
      echo "» ------------------------------------------------------------- «"
      echo "» -- Running backup script (to create very first own backup) -- «"
      echo "» ------------------------------------------------------------- «"
      echo
  
      # Do backup
      source backup init
      
    # Else clear one line
    else
      clear_last_lines 1
    fi
  fi
}

# Get parent repo
get_parent_repo() {

  # Argument #1: repo for which parent should be detected
  local repo="${1}"
  local detect_child_type="${2:-}"

  # Shortcut to json query
  local url
  local info
  local parent_repo
  local hdr

  # Set auth header
  if [[ ! -z "${GH_TOKEN:-}" ]]; then
    hdr="Authorization: Bearer ${GH_TOKEN}"
  else
    hdr=""
  fi

  # Get current repo info
  set +e
  url="https://api.github.com/repos/${repo}"
  info=$(curl -sS -H "$hdr" --fail-with-body "$url" 2>&1); exit_code=$?
  set -e

  # If request failed - print 'null' and return error
  if [[ exit_code -ne 0 ]]; then
    echo "null"
    echo "$url" >&2
    echo "$info" >&2
    return 1

  # Else
  else

    # Find parent repo info via regular expressions
    info="$(echo "$info" | tr -d '\n' | (grep -Pzo '"(?:parent|template_repository)": \{[^{}]+?"full_name": "(.+?)"' || true) | tr -d '\0')"

    # If nothing found - print 'null'
    if [[ $info = "" ]]; then echo "null";

    # Else
    else

      # Print parent repo to stdout
      echo -n "$info" | sed -E 's~.*"full_name": "([^"]*)".*~\1~'

      # If $detect_child_type arg is given as true - do it
      if [[ "$detect_child_type" = true ]]; then
        if echo "$info" | grep -q 'template_repository'; then
          echo -n ":generated"
        else
          echo -n ":forked" # Assuming if not template_repository, it's a direct fork
        fi
      fi
      echo
    fi
  fi
}

# Unzip given file into a given destination
unzip_file() {

  # Arguments
  local file=$1
  local dest=$2
  local owner=${3:-}

  # Remove contents of existing destination dir, if any
  [[ -d $dest ]] && rm -rf "$dest"/*

  # Count total quantity of files in the archive
  local qty=$(7z l "$file*" | grep -cE '^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2} [^ ]')

  # Prepare messages
  local m1="Unzipping" && local m2="files into $dest/ dir..."

  # Prepare 7z command opts
  local opts="x -y -o$dest -bso0 -bse0"

  # If we're within an interactive shell
  if [[ $- == *i* || -n "${FLASK_APP:-}" ]]; then

    # Extract with progress tracking
    echo "$m1 $qty $m2"
    7z $opts -bsp1 "$file*"
    clear_last_lines 1
    echo "$m1 $qty $m2 Done"

  # Else extract with NO progress tracking
  else
    echo -n "$m1 $qty $m2" && 7z $opts "$file*" && echo " Done"
  fi

  # If $owner arg is given - apply ownership for the destination dir
  if [[ -n $owner ]]; then
    if [[ ! -d "$dest" ]]; then mkdir -p "$dest"; fi
    echo -n "Making that dir writable for Indi Engine..."
    chown -R "$owner" "$dest"
    echo -e " Done"
  fi
}

# Get release title by release tag
# This function expects releases are already loaded via 'gh release ls' command
get_release_title() {

  # Arguments
  local tag=$1

  # If release does not exist - print error and exit
  if [[ ! -v releases["$tag"] ]]; then
    echo "Release '$tag' not found" >&2
    exit 1
  fi

  # Get release title
  local title=$(echo -e "${releases[$tag]}" | sed -e 's/\x1b\[[0-9;]*m//g')
  title=$(echo -e "${releases[$tag]}" | cat -v | sed -E 's~\^(\[[^m]+?m|M)~~g' | sed -E 's~M-BM-7~-~g')
  length=${release_choice_title_length:-37}
  title=$(echo "${title:0:$length}")
  title="${title%"${title##*[![:space:]]}"}"
  title=$(echo "$title" | sed -E 's~ - ~ · ~g')

  # Print title
  echo $title
}

# Check if we're in an 'uncommitted_restore' state, which is true if both conditions are in place:
# 1.We're currently in a detached head state
# 2.Note of a current commit ends with ' · abc1234' where abc1234 is a first 7 chars of a commit hash
is_uncommitted_restore() {
  [[ "$(git rev-parse --abbrev-ref HEAD)" = "HEAD" ]] && \
  [[ "$(git notes show 2>/dev/null)" =~ \ ·\ [a-f0-9]{7}$ ]]
}

# Prepend each printed line with string given by 1st arg
prepend() {

  # Arguments
  local prefix="${1:-}"
  local count="${2:-}"

  # Lines counter
  local qty=0

  # File to write counter value
  local qtyfile=$DOC/var/prepended

  # If $count-arg is true - count the lines by writing to a file
  # as this is the only way to recall the resulting value of $qty
  if [[ "$count" == true ]]; then echo "$qty" > "$qtyfile"; fi

  # Foreach line
  while IFS= read -r line; do

    # Print using gray color and with given $prefix
    printf "${gray}%s%s\n${d}" "$prefix" "$line"

    # Increment local $counter variable and write it's value into a file to be further accessible
    if [[ "$count" == true ]]; then
      qty=$((qty + 1)); echo "$qty" > "$qtyfile"
    fi
  done
}

# Get hash of a commit where HEAD is right now
get_head() {
  git rev-parse HEAD
}

# If we're going to enter into an 'uncommitted restore' state then
# do a preliminary local backup of current state so that we'll be
# able to get back if restore will be cancelled
backup_current_state_locally() {
  if ! is_uncommitted_restore; then
    echo -e "Backing up the current version locally before restoring the selected one:"
    source maintain/uploads-prepare.sh ${1:-} "» "
    source maintain/dump-prepare.sh "${1:-}" "» "
    echo ""
  fi
}

# Restore source code
restore_source() {

  # Arguments
  local release=$1
  local dir=${2:-custom}

  # Get release title
  local title=$(get_release_title $release)

  # Get commit hash for the $release
  local repo=$(get_current_repo)
  echo -n "Detecting commit hash for selected version..."
  local hash=$(get_tag_hash $release)
  echo " Done"
  echo -e "Result: $hash\n"

  # Get hash of current HEAD
  local head=$(git rev-parse HEAD)

  # Restore source code to a selected point in history
  echo -n "Restoring source code for selected version..."

  # If we are already in 'detached HEAD' (i.e. 'uncommitted restore') state
  if is_uncommitted_restore; then

    # Cleanup uncommitted changes, if any, to prevent conflict with the state to be further checked out
    if ! git diff --quiet || ! git diff --cached --quiet; then
        git stash --quiet && git stash drop --quiet;
    fi

    # Cleanup previously applied commit note, to prevent misleading info from being shown in 'git log'
    # We do that because notes here are used as a temporary reminder of which backup was restored, but
    # the fact we're here assumes we're going to restore another backup than the currently restored one
    # and in most cases this means HEAD will be moved to another commit, so we don't need the note we've
    # added for the current commit i.e. where HEAD is at the moment, because note should be added only
    # for the most recent uncommitted restore, because when committed - note comment will be used to
    # prepare commit message for it to contain the name of backup that was finally restored, because
    # we can't rely for that on anything else, as backup tags are rotating and commit hashes are not
    # unique across tags as there might be multiple backups having tags pointing to equal commit hashes,
    # so the commit hash of a backup does NOT uniquely identify the backup
    if git notes show "$head" > /dev/null 2>&1; then git notes remove "$head" > /dev/null 2>&1; fi
  fi

  # Restore the whole repo at selected point in history
  git checkout -q "$hash" 2>&1 | prepend "» "
  echo -e " Done"

  # Apply DevOps patch so that critical files a still at the most recent state
  echo -n "Forcing DevOps-setup files to be still at the latest version..."
  git checkout main -- . ":(exclude)$dir"
  echo " Done"

  # Add note
  git notes add -f -m "$title · ${hash:0:7}"

  # Apply composer packages state
  echo "Setting up composer packages state:"
  composer -d custom install --no-ansi 2>&1 | grep -v " fund" | prepend "» "
  echo ""
}

# Load releases from github, force user to select one
# and set up selected-variable containing selected release's tag
release_choices() {

  # Arguments
  local to_be_done=${1:-"to be restored"}
  if [[ "${2:-0}" == "1" ]]; then local auto_choose="most recent"; else local auto_choose=${2:-0}; fi
  local repo="${3:-$(get_current_repo)}"

  # Load releases list
  echo -n "Loading list of backup versions available on github..."
  declare -Ag releases=()

  # If GitHub CLI will be used
  if [[ ! -z "${GH_TOKEN:-}" ]]; then

    local lerr="var/log/release_list.stderr"
    local list=$(script -q -c "gh release -R $repo list 2> $lerr" /dev/null)
    if [[ -s "$lerr" ]]; then echo ""; cat "$lerr" >&2; exit 1; fi
    rm -f "$lerr";
    echo " Done"

    # Split $list into an array of lines
    mapfile -t lines < <(printf '%s\n' "$list")

    # Get index of 'TAG NAME' within the header line
    local header=$(echo -e "${lines[0]}" | cat -v | sed -E 's~\^(\[[^m]+?m|M)~~g') && index=${header%%"TAG NAME"*} && index=${#index}
    local up_to_type=${header%%"TYPE"*}
    release_choice_title_length=${#up_to_type}

    # Get header, with removing it out of the lines array
    header=$(echo -e " ?  ${lines[0]}" | perl -pe 's/\e\[[0-9;?]*[A-Za-ln-zA-Z]//g' | sed -E 's~\x1b][0-9]+;\?~~g'); unset 'lines[0]'

    # Re-index lines array
    lines=("${lines[@]}")

    # Prepare unsorted releases-array of [tag => name] pairs from raw $lines
    for idx in "${!lines[@]}"; do
      tag=$(echo -e "${lines[$idx]}" | cat -v | sed -E 's~\^(\[[^m]+?m|M)~~g' | sed -E 's/M-BM-7/-/g')
      tag=$(echo "${tag:$index}") && tag="${tag%% *}"
      releases[$tag]=${lines[$idx]}
    done

  # Else if GitHub API will be used
  else

    # Load releases into releases-array
    load_releases "$repo"
    echo " Done"

    # Imitate header
    lines[0]="]11;?\[6n]11;?\[6n[0;2;4;37mTITLE                              [0m  [0;2;4;37mTYPE  [0m  [0;2;4;37mTAG NAME[0m  [0;2;4;37mPUBLISHED        [0m"

    # Get index of 'TAG NAME' within the header line
    local header=$(echo -e "${lines[0]}" | cat -v | sed -E 's~\^(\[[^m]+?m|M)~~g') && index=${header%%"TAG NAME"*} && index=${#index}
    local up_to_type=${header%%"TYPE"*}
    release_choice_title_length=${#up_to_type}

    # Get header, with removing it out of the lines array
    header=$(echo -e " ?  ${lines[0]}" | perl -pe 's/\e\[[0-9;?]*[A-Za-ln-zA-Z]//g' | sed -E 's~\x1b][0-9]+;\?~~g'); unset 'lines[0]'
  fi

  # If no releases exist in github for $repo - print error and return
  if [[ "${#releases[@]}" -eq 0 ]]; then
    echo "No backup versions available on github for ${g}${repo}${d} repo"
    set +e
    return 1
  fi

  # Prepare sorted_tags 0-indexed array from releases associative array
  # We do that this way because the order of keys in associative array in Bash - is NOT guaranteed
  # Sorting is done by env code index ascending and then the release visible date descending
  sort_releases

  # Prepare choices in the right order
  choices=() && for tag in "${sorted_tags[@]}"; do choices+=("${releases["$tag"]}"); done

  # If the most recent backup should be auto-selected - we don't ask user to choose
  if [[ "$auto_choose" = "most recent" ]]; then

    # Get text
    choice_idx=${default_release_idx}
    choice_txt=${choices[$default_release_idx]}

  # Else if arbitrary backup should be manually selected
  elif [[ "$auto_choose" = "0" ]]; then

    # Print instruction on how to use keyboard keys
    echo "Please select the version you want $to_be_done"
    echo -e "Use the ↑ and ↓ keys to navigate and press Enter to select or Ctrl+C to cancel\n"

    # Ask user to choose and set choice-variable once done
    echo "$header" && read_choice $default_release_idx
  fi

  # If it was manual choice or auto choice ofmost recent backup
  if [[ "$auto_choose" = "0" || "$auto_choose" = "most recent" ]]; then

    # Parse the tag of selected backup
    selected=$(echo -e "$choice_txt" | sed -e 's/\x1b\[[0-9;]*m//g' -e 's/·/-/g')
    selected=$(echo "${selected:$index}") && selected="${selected%% *}"
    echo ""

  # Else set up selected to be the one given as 2nd arg
  else
    echo ""
    selected="$auto_choose"
  fi
}

# Cancel source code restore, i.e. revert source code to the state which was before restore
cancel_restore_source() {

  # Print where we are
  echo -n "Cancelling source code restore..."

  # Remove notes
  git notes remove "$(get_head)" 2> /dev/null

  # Cleanup uncommitted changes, if any, to prevent conflict with the state to be further checked out
  if ! git diff --quiet || ! git diff --cached --quiet; then
      git stash --quiet && git stash drop --quiet;
  fi

  # Restore source code at main-branch
  git checkout -q main

  # Print done
  echo -e " Done"

  # Revert composer packages state
  echo "Setting up composer packages state:"
  composer -d custom install --no-ansi 2>&1 | grep -v " fund" | prepend "» "
}

# Cancel uploads restore, i.e. revert uploads to the state which was before restore
cancel_restore_uploads_and_dump() {

  # Move uploads.zip and dump.sql.gz files from data/before/ to data/
  # for those to be further picked by restore_uploads() call and mysql re-init
  src="data/before" && trg="data"
  echo -n "Moving uploads.zip and dump.sql.gz from $src/ into $trg/..."
  if [ -d $src ]; then
    rm -f data/uploads.z*
    mv -f "$src"/* "$trg"/ && rm -r "$src"
  fi
  echo -e " Done\n"

  # Revert uploads to the state before restore
  # We call this function here with no 1st arg (which normally is expected to be a release tag)
  # to skip the downloading uploads.zip file from github, so that the local uploads.zip file
  # we've moved into data/ dir from data/before/ dir - will be used instead
  restore_uploads

  # Separate with new line
  echo ""

  # Revert database to the state before restore
  # We call this function here with no 1st arg (which normally is expected to be a release tag)
  # to skip the downloading dump.sql.gz file from github, so that the local dump.sql.gz file
  # we've moved into data/ dir from data/before/ dir - will be used instead
  restore_dump
}

# Prepare $tag variable containing the right tag name for the new backup and do a rotation step if need
prepare_backup_tag() {

  # Argument: name of backup rotation period, which is expected to be 'hourly', 'daily', 'weekly', 'monthly' or 'custom'
  rotation_period_name=${1:-custom}
  p=${2:-}

  # Setup auxiliary variables
  setup_auxiliary_variables

  # Setup values for is_rotated_backup and rotated_qty variables
  check_rotated_backup

  # Load releases list from github into array of [tagName => title] pairs
  # Note: $repo variable is globally set by setup_auxiliary_variables() call
  echo -n "${p}Loading list of '$rotation_period_name'-backups available on github..."
  load_releases "$repo"
  echo " Done"

  # If it's a rotated backup
  if (( is_rotated_backup )); then

    # Print a newline
    echo -e "\n${p}Rotating backups:"

    # Iterate over each expected backup starting from the oldest one and up to the most recent one
    for ((backup_idx=$((rotated_qty-1)); backup_idx>=0; backup_idx--)); do

      # Get the tag name for the backup at the given index
      # within the history of backups for the given period
      tag="${tag_prefix}${backup_idx}"

      # If the index refers to the oldest possible backup
      if [[ $backup_idx -eq $((rotated_qty - 1)) ]]; then

        # Print where we are
        echo -n "${p}» Oldest: $tag - "

        # Delete backup (if exists)
        delete_release "$tag"

      # Else if the index refers to intermediate or even the newest
      # backup within the history of backups for the given period
      else

        # Print where we are
        if [[ $backup_idx -ne 0 ]]; then
          echo -n "${p}» Newer : $tag - "
        else
          echo -n "${p}» Newest: $tag - "
        fi

        # Move release (if exists) from current tag to older tag
        retag_release "$tag" "${tag_prefix}$((backup_idx + 1))"
      fi
    done

    # Prepare backup title looking like 'Production · D0 · 07 Dec 24, 14:00'
    point=${tag:1} && title="${APP_ENV^}${delim}${point^^}${delim}$(date +"%d %b %y, %H:%M")"

  # Else
  else

    # Setup tag name for non-rotated backup to be equal to 1st arg (if given) or 'latest'
    tag=${1:-latest}

    # Setup release title to be the same as tag name
    title="$tag"
  fi

  # If backup does not really exists under given tag - create it
  if ! has_release "$tag"; then
    created=$(gh release create "$tag" --title="$title" --notes="" --target="$(get_head)")
    echo -n "${p}Newest: $tag - created"
  else
    echo -n "${p}Newest: $tag - exists, will be updated"
  fi
}

# Make restored version to become the new latest
commit_restore() {

  # Prompt for GIT_COMMIT_NAME and/or GIT_COMMIT_EMAIL if any missing
  prompt_git_commit_identify_if_missing

  # Print where we are
  echo "Make restored version to become the new latest:"

  # Get title and commit hash of the restored version
  echo -n "» Detecting restored version title and commit hash..."
  version=$(git notes show) && hash=$(get_head)
  echo " Done"

  # Checkout whole working dir was the latest version
  echo -n "» Switching source code to the latest version..."
  git checkout main > /dev/null 2>&1
  echo " Done"

  # However, checkout custom dir at the restored version
  echo -n "» Switching source code in custom/ dir to the restored version..."
  git restore --source "$hash" custom
  git add custom
  echo " Done"

  # Create a commit to make the restore to be a point in the project history
  # If there were no really changes in custom since restored version - we still create a commit
  # Remove that note from commit, so note is now kept in $note variable only
  echo -n "» Committing this state as a new record in source code history..."
  git commit --allow-empty -m "RESTORE COMMITTED: $version" > /dev/null
  git notes remove "$hash" 2> /dev/null
  echo " Done"

  # Push changes to remote repo, and pull back for git log to show last commit in origin/main as well
  echo ""
  git remote set-url origin https://$GH_TOKEN_CUSTOM_RW@github.com/$(get_current_repo)
  git push
  pull=$(git pull) && [[ ! "$pull" = "Already up to date." ]] && echo -e "\n$pull";

  git remote set-url origin https://-@github.com/$(get_current_repo)

  # Print restore is now committed
  echo -e "\nRESTORE COMMITTED: ${g}${version}${d}\n"
}


# Make the original version, which was active BEFORE you've entered
# in an 'uncommitted restore' state - to be also restorable
backup_before_restore() {

  # Print where we are
  echo "Make 'before restore' version to be also restorable:"
  echo "» ---"

  # Assets dir where dump.sql.gz and uploads.zip
  # were created before restore, and still kept
  dir="data/before"

  # Backup those assets into github under 'before' tag
  backup_prepared_assets "before" "$dir"

  # Remove from local filesystem
  [ -d "$dir" ] && rm -R "$dir"

  # Print new line
  echo ""
}

mysql_entrypoint() {

  # Path to a file to be created once init is done
  done=/var/lib/mysql/init.done;

  # Path where mysql binaries should be copied
  vmd="/usr/bin/volumed"

  # If it does not exist
  if [[ ! -f "$vmd/mysql" ]]; then

    # Сopy 'mysql' and 'mysqldump' command-line utilities into it, so that we can share
    # those two binaries with apache-container to be able to export/import sql-files
    src="/usr/bin"
    cp "$src/mysql"     "$vmd/mysql"
    cp "$src/mysqldump" "$vmd/mysqldump"
  fi

  # If init is not done
  if [[ ! -f "$done" ]]; then

    # Change dir
    cd /docker-entrypoint-initdb.d

    # Remove any existing files from current dir (i.e. /docker-entrypoint-initdb.d/)
    # that are recognized by mysql entrypoint as importable/executable ones
    rm -f ./*.sh ./*.sql ./*.sql.bz2 ./*.sql.gz ./*.sql.gz[0-9][0-9] ./*.sql.xz ./*.sql.zst

    # Shortcut to native entrypoint
    native="/usr/local/bin/docker-entrypoint.sh"

    # If 'init.done' file creation code was not yet added to native entrypoint script
    if ! grep -q "init.done" $native; then

      # Append touch-command to create an empty '/var/lib/mysql/init.done'-file after init is done to use in healthcheck
      sed -i 's~Ready for start up."~&\n\t\t\ttouch /var/lib/mysql/init.done~' $native
    fi
  fi

  # Call the original entrypoint script
  /usr/local/bin/docker-entrypoint.sh "$@"

  # If we reached this line, it means mysql was shut down
  echo "MySQL Server has been shut down"

  # Create a file within data-dir to indicate shutdown is completed
  touch /var/lib/mysql/shutdown.done

  # Wait until shutdown is really completed
  local timeout=5
  local elapsed=0
  local data="/var/lib/mysql"
  while [ ! -z "$(ls -A $data)" ] && [ $elapsed -lt $timeout ]; do
    echo "Waiting for data-directory to be emptied... ($elapsed s)"
    sleep 1
    elapsed=$((elapsed + 1))
  done

  # If data-directory was emptied
  if [ -z "$(ls -A $data)" ]; then

    # We assume it was done for restore
    echo "MySQL data-directory has been emptied, so initiating the restore..."

    # Re-init
    mysql_entrypoint "$@"
  fi
}

# Check if a certain flag is given within the list of arguments
has_flag() {
    local flag="$1"
    shift
    for arg in "$@"; do
        [[ "$arg" == "$flag" ]] && return 0
    done
    return 1
}

# Convert ISO8601 UTC format (i.e. 2025-06-09T15:35:42Z) to 'x month/minutes/etc ago'
time_ago() {
    local iso_time="$1"
    local ts now diff value unit

    # Convert ISO8601 to epoch seconds (GNU date for Linux)
    ts=$(date -d "$iso_time" +%s 2>/dev/null) || return 1
    now=$(date +%s)
    diff=$((now - ts))

    # Get diff and unit
    if (( diff < 60 )); then value=$diff; unit="sec"
    elif (( diff < 3600 )); then value=$((diff / 60)); unit="min"
    elif (( diff < 86400 )); then value=$((diff / 3600)); unit="hr"
    #elif (( diff < 604800 )); then value=$((diff / 86400)); unit="day"
    elif (( diff < 2592000 )); then value=$((diff / 86400)); unit="day"
    #elif (( diff < 2592000 )); then value=$((diff / 604800)); unit="week"
    elif (( diff < 31536000 )); then value=$((diff / 2592000)); unit="month"
    else value=$((diff / 31536000)); unit="year"; fi

    # Handle plural
    if (( value == 1 )); then
      echo "$value $unit ago"
    else
      echo "$value ${unit}s ago"
    fi
}

# Format releases list line in the similar way as 'gh release list' does
format_release_line() {

    # Arguments
    local name="${1:-}"
    local latest_tag="${2:-}"
    local tag_name="${3:-}"
    local published_at="${4:-}"

    # Setup type
    if [[ "$tag_name" = "$latest_tag" ]]; then
      local type="Latest"
    else
      local type=""
    fi

    # Format in the similar way as 'gh release list' does
    echo -e "$(str_pad "$name" 36) \e[92m$(str_pad "$type" 7)\e[0m $(str_pad "$tag_name" 9) \e[90mabout$(time_ago "$published_at")\e[0m"
}

# Pad given string with whitespaces up to given total length
str_pad() {

  # Arguments
  local str="${1:-}"
  local len=$2

  # Replace '·' with '-' and get correct length
  local txt=$(echo "$str" | sed -E 's~ · ~ - ~g')
  local own=${#txt}

  # Print string and spaces
  echo -n "$str"; printf '%*s' $(( len - own )) ''
}

# Calculate latest release tag by published_at prop
get_latest_release() {

  # Arguments
  local list="$1"

  # Initial value
  local latest_tag=""

  # Foreach line in the $list
  while IFS="=" read -r tag_name name published_at; do
    if [[ "$latest_tag" = "" || "$published_at" > "$latest_pub" ]]; then
      local latest_tag="$tag_name"
      local latest_pub="$published_at"
    fi
  done < <(echo "$list")

  # Print latest
  echo "$latest_tag"
}

# Entrypoint script for wrapper-container
wrapper_entrypoint() {

  # Setup git commit author identity
  if [[ ! -z "$GIT_COMMIT_NAME"   && -z $(git config user.name)  ]]; then git config user.name  "$GIT_COMMIT_NAME" ; fi
  if [[ ! -z "$GIT_COMMIT_EMAIL"  && -z $(git config user.email) ]]; then git config user.email "$GIT_COMMIT_EMAIL"; fi

  # Add github.com to known hosts, if missing
  if [[ ! -d ~/.ssh ]]; then mkdir ~/.ssh; fi; known=~/.ssh/known_hosts;
  if [[ ! -f $known ]] || ! grep -q "github.com" $known; then ssh-keyscan github.com >> $known; fi

  # Setup github token for composer
  composer --global config github-oauth.github.com "$(get_env "GH_TOKEN_SYSTEM_RO")"

  # Setup git filemode
  git config --global core.filemode false

  # Copy 'mysql' and 'mysqldump' binaries to /usr/bin, to make it possible to restore/backup the whole database as sql-file
  cp /usr/bin/mysql_client_binaries/* /usr/bin/

  # Logs dir
  logs="$DOC/var/log/compose/wrapper"

  # Trim leading/trailing whitespaces from domain name(s)
  LETS_ENCRYPT_DOMAIN=$(echo "${LETS_ENCRYPT_DOMAIN:-}" | xargs)
  EMAIL_SENDER_DOMAIN=$(echo "${EMAIL_SENDER_DOMAIN:-}" | xargs)

  # If $EMAIL_SENDER_DOMAIN is empty - use LETS_ENCRYPT_DOMAIN by default
  if [[ ! -z "$LETS_ENCRYPT_DOMAIN" ]]; then
    if [[ -z "$EMAIL_SENDER_DOMAIN" ]]; then
      EMAIL_SENDER_DOMAIN=$LETS_ENCRYPT_DOMAIN
    fi
  fi

  # Configure postfix and opendkim to ensure outgoing emails deliverability
  if [[ ! -z "$EMAIL_SENDER_DOMAIN" ]]; then

    # Shortcuts
    dkim="/etc/opendkim"
    selector="mail"
    conf="/etc/postfix/main.cf"
    sock="inet:localhost:8891"
    user="www-data"

    # If trusted.hosts file does not yet exist - it means we're setting up opendkim for the very first time
    if [[ ! -f "$dkim/trusted.hosts" ]]; then
      echo -e "127.0.0.1\nlocalhost" >> "$dkim/trusted.hosts"
    fi

    # Setup postfix to use opendkim as milter
    if ! grep -q $sock <<< "$(<"$conf")"; then
      echo "smtpd_milters = $sock"            >> $conf
      echo "non_smtpd_milters = $sock"        >> $conf
      echo "maillog_file = $logs/postfix.log" >> $conf
      echo "debug_peer_level = 2"             >> $conf
      echo "debug_peer_list = 127.0.0.1"      >> $conf
    fi

    # Split LETS_ENCRYPT_DOMAIN into an array
    IFS=' ' read -r -a senders <<< "$EMAIL_SENDER_DOMAIN"

    # Use first item of that array as myhostname in postfix config
    # This is executed on container (re)start so you can apply new value without container re-creation
    sed -Ei "s~(myhostname\s*=)\s*.*~\1 ${senders[0]}~" "$conf"

    # Iterate over each domain for postfix and opendkim configuration
    for maildomain in "${senders[@]}"; do
      domainkeys="$dkim/keys/$maildomain"
      priv="$domainkeys/$selector.private"
      DNSname="$selector._domainkey.$maildomain"

      # If private key file was not generated so far
      if [[ ! -f $priv ]]; then

        # Generate key files
        mkdir -p $domainkeys
        opendkim-genkey -D $domainkeys -s $selector -d $maildomain

        # Setup key.table, signing.table and trusted.hosts files to be picked by opendkim
        echo "$DNSname $maildomain:$selector:$priv"   >> "$dkim/key.table"
        echo "*@$maildomain $DNSname"                 >> "$dkim/signing.table"
        echo "*.$maildomain"                          >> "$dkim/trusted.hosts"
      fi

      # Refresh permissions
      chown opendkim:opendkim "$priv"
      chown $user:$user "$domainkeys/$selector.txt"
    done
  fi

  # Start opendkim and postfix to be able to send DKIM-signed emails via sendmail
  if [[ -f "/etc/opendkim/trusted.hosts" ]]; then service opendkim start; fi
  service postfix start

  # Refresh token
  export GH_TOKEN_CUSTOM_RW="$(get_env "GH_TOKEN_CUSTOM_RW")"

  # Export GH_TOKEN from $GH_TOKEN_CUSTOM_RW
  [[ ! -z $GH_TOKEN_CUSTOM_RW ]] && export GH_TOKEN="${GH_TOKEN_CUSTOM_RW:-}"

  # Setup crontab
  export TERM=xterm && env | grep -E "MYSQL|GIT|GH|DOC|EMAIL|TERM|BACKUPS|APP_ENV" >> /etc/environment
  sed "s~\$DOC~$DOC~" 'compose/wrapper/crontab' | crontab -
  service cron start

  # If GH_TOKEN is set it means we'll work via GitHub CLI, so set current repo as default one for that tool
  if [[ ! -z "${GH_TOKEN:-}" ]]; then
    gh repo set-default "$(get_current_repo)"
  fi

  # Run HTTP api server
  FLASK_APP=compose/wrapper/api.py flask run --host=0.0.0.0 --port=80

  # If we reached this line, it means mysql was shut down
  echo "Flask server has been shut down"

  # Re-start flask
  #wrapper_entrypoint "$@"
}

# Function to execute on exit
function on_exit() {

  # Get the exit code of the last command/script
  local exit_code=$?

  # If it's a error exit code and current execution was not triggered from Flask
  if [ "$exit_code" -ne 0 ] && [ -z "${FLASK_APP:-}" ]; then

    # Wait for user to press any key
    echo "-----"
    echo "ERROR: Script terminated with exit code $exit_code."
    echo "Press any key..."
    read -n 1 -r

    # Keep interactive window
    exec bash
  fi
}

# Function to execute a shell command with optional folder context, silent mode, and failure tolerance
exec_command() {

  # Arguments
  local command="$1"
  local folder="${2:-}"
  local no_exit_on_failure_if_msg_contains="${3:-}"
  local silent="${4:-false}"

  # Aux variables
  local wasdir exit_code

  # Change to target folder if provided
  if [[ -n "$folder" ]]; then
      wasdir="$(pwd)"
      cd "$folder" || return 1
  fi

  # Execute command, capture output and exit code
  set +e
  stdout="$($command 2>&1)"
  exit_code=$?
  set -e

  # Restore previous directory
  if [[ -n "$folder" ]]; then
      cd "$wasdir" || return 1
  fi

  # If success, return output
  if [[ $exit_code -eq 0 ]]; then
      return 0
  fi

  # If failure but output contains specified string, return 1 silently
  if [[ -n "$no_exit_on_failure_if_msg_contains" ]] && grep -q "$no_exit_on_failure_if_msg_contains" <<< "$stdout"; then
      return 1
  fi

  # Else show output and return failure
  echo "$stdout"
  return 1
}

# Check if given repo is outdated
is_repo_outdated() {

  # Arguments
  local repo="$1"

  # Variables
  local url=
  local dir=
  local branch=

  # Prepare url to check last commit
  if [[ "$repo" = "custom" ]]; then
    url="https://github.com/$(get_current_repo)"
    branch=main
    git_askpass "custom"
  else
    url="https://github.com/indi-engine/$repo"
    branch=master
    dir="$VDR/$repo"
    git_askpass "system"
  fi

  # Get last commit on remote
  stdout="$(git ls-remote -h -t "$url" $branch 2>&1)"; exit_code=$?
  if [[ $exit_code -ne 0 ]]; then
    echo -e "\n$stdout"
    exit $exit_code
  fi
  stdout="$(echo "$stdout" | xargs)"
  commit="${stdout%% *}"

  # Check if that commit exists locally
  set +e; stdout="$(git -C "$dir" branch --contains "$commit" 2>&1)"; exit_code=$?;

  # If exists, it means repo is NOT outdated, so return exit code 1
  if [[ $exit_code -eq 0 ]]; then
    stdout="$commit"
    return 1
  elif [[ "$stdout" =~ "no such commit" ]]; then
    return 0
  else
    echo -e "\n$stdout"
    exit $exit_code
  fi
}

# Check whether composer.lock is outdated for a given indi-engine repo and commit hash
is_lock_outdated() {

  # Arguments
  local repo="$1"
  local commit="$2"

  # Auxiliary variable
  local reference

  # Extract the 'reference' for the matching package from composer.lock
  reference=$(jq -r --arg repo "indi-engine/$repo" '
      .packages[] | select(.name == $repo) | .source.reference
  ' custom/composer.lock)

  # If reference not found, package doesn't exist — consider outdated
  if [[ -z "$reference" || "$reference" == "null" ]]; then
      return 0  # outdated
  fi

  # If the commit doesn't match the reference — it's outdated
  if [[ "$reference" != "$commit" ]]; then
      return 0  # outdated
  fi

  # Return 1 to indicate that lock file is NOT outdated
  return 1
}

# Make sure a certain token will be used for any subsequent git-command calls
git_askpass() {

  # Arguments
  local token="${1:-}"

  # Set GH_TOKEN based on $token-arg
  if [[ "$token" = "custom" ]]; then
    export GH_TOKEN="$(get_env "GH_TOKEN_CUSTOM_RW")"
  elif [[ "$token" = "system" ]]; then
    export GH_TOKEN="$(get_env "GH_TOKEN_SYSTEM_RO")"
  elif [[ "$token" = "parent" ]]; then
    export GH_TOKEN="$(get_env "GH_TOKEN_PARENT_RO")"
  else
    export GH_TOKEN=""
  fi

  # Setup GIT_ASKPASS
  local dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  local pass="$dir/git-askpass.sh"
  export GIT_ASKPASS="$pass"
  chmod +x "$pass"
}

# Do restart, if needed according to scenario, if written to var/restart
# IMPORTANT: This function is intended to be called on host only
restart_if_need() {

  # Get restart scenario as 1st arg
  scenario="${1:-}"

  # ./update artifact file where restart scenario might be stored
  artifact=var/restart

  # If restart scenario is from 1 to 4
  if [[ "$scenario" =~ (1|2|3|4) ]]; then

    # Pick GH_TOKEN_CUSTOM_RO from .env
    export GH_TOKEN_SYSTEM_RO="$(get_env "GH_TOKEN_SYSTEM_RO")"

    # Pull base images and/or rebuild own ones, if need
    if [[ "$scenario" == 1 ]]; then docker compose build --pull;  echo 3 > "$artifact"; scenario=3; fi
    if [[ "$scenario" == 2 ]]; then docker compose build;         echo 3 > "$artifact"; scenario=3; fi

    # Stop maxwell and closetab, if need
    docker compose exec -it wrapper bash -c "source maintain/functions.sh; stop_maxwell_and_closetab_if_need"

    # Act further according to current restart level
    case "$scenario" in
      3) docker compose up --force-recreate -d ;;
      4) docker compose restart ;;
    esac

  # Else assume we may have update artifact containing restart scenario
  elif [[ "$scenario" == "" ]]; then

    # If update artifact file exists
    if [[ -f "$artifact" ]]; then

      # Restart according to scenario
      restart_if_need "$(<"$artifact")"

      # Remove artifact file
      rm -f "$artifact"
    fi
  else
    echo "Unknown restart scenario: $scenario"
  fi
}

# Get hash of the commit up to which the db migrations are executed
get_migration_commit() {

  # Arguments
  local fraction="${1:-}"

  # Add mysql password to env
  export MYSQL_PWD=$MYSQL_PASSWORD

  # Get commit
  mysql -D custom -N -e 'SELECT `defaultValue` FROM `field` WHERE `alias` = "migration-commit-'"$fraction"'"'

  # Remove mysql password from env
  unset MYSQL_PWD
}

# Set hash of the commit up to which the db migrations are executed
set_migration_commit() {

  # Arguments
  local fraction=$1
  local commit=$2

  # Add mysql password to env
  export MYSQL_PWD=$MYSQL_PASSWORD

  # Get commit
  mysql -D custom -N -e 'UPDATE `field` SET `defaultValue` = "'"$commit"'" WHERE `alias` = "migration-commit-'"$fraction"'"'

  # Remove mysql password from env
  unset MYSQL_PWD
}

# Run database migrations, if any new ones detected for system and/or custom fractions
migrate_if_need() {

  # Migration actions will be collected here
  declare -A migrate=()

  # Foreach fraction
  for fraction in system custom; do

    # Print status
    echo "Checking $fraction fraction:"

    # Setup a file to detect changes in and fraction folder where it's located
    if [[ "$fraction" == "system" ]]; then
      folder="$VDR/system"
      detect="library/Indi/Controller/Migrate.php"
    else
      folder="custom"
      detect="application/controllers/admin/MigrateController.php"
    fi

    # Get hash of the last commit up to which migrations were run
    commit=$(get_migration_commit "$fraction")

    # If none - use HEAD commit
    if [[ $commit == "" ]]; then commit="$(git -C "$folder" rev-parse HEAD)"; fi

    # Try to get the list of changed files
    set +e; files=$(git -C "$folder" diff --name-only "$commit" 2>&1); exit_code=$?; set -e

    # If the above 'git diff ...' command failed
    if [[ "$files" == *"fatal: bad object"* ]] && [[ exit_code -ne 0 ]]; then

      # If it failed because of $commit does not exist in custom repo
      if [[ $fraction == "custom" ]]; then

        # Get the very first commit
        commit=$(git -C "$folder" rev-list --max-parents=0 HEAD)

        # Get files changed since the very first commit, if any
        files=$(git -C "$folder" diff --name-only "$commit" 2>&1)

      # Else exit with error code 1
      else
        echo "$files" >&2
        exit $exit_code
      fi
    fi

    # If migration controller php file was changed for $fraction
    if grep -qxF "$detect" <<< "$files"; then

      # Get diff
      diff="$(git -C "$folder" diff "$commit" -- "$detect")"

      # Setup regex to detect added migration actions
      rex='^\+\s+public function ([a-zA-Z_0-9]+)Action'

      # Detect migration actions
      actions=$(echo "$diff" | (grep -P "$rex" || true) | sed -E "s~$rex.*~\1~" | tac)

      # If no new migrations detected - print that
      if [[ "$actions" == "" ]]; then
        echo "no migrations were added" | prepend "» "

      # Else add to the pending migration list and print status
      else
        for action in $actions; do migrate["$fraction"]+="migrate/$action "; done
        echo "$(echo "$actions" | wc -l) new migration(s) detected" | prepend "» "
      fi

    # Else print status
    else
      echo "no migrations were added" | prepend "» "
    fi

    # If php-file responsible for turning On localization for certain fields - was NOT changed for $fraction
    if ! grep -qxF "application/lang/ui.php" <<< "$files"; then
      echo "no locale meta was changed" | prepend "» "

    # Else add to the pending migration list and print status
    else
      migrate["$fraction"]+="lang/import/meta?$fraction "
      echo "locale meta change detected" | prepend "» "
    fi

    # Collect [lang => file] pairs for changed files responsible for actual translations for certain language
    declare -A l10n_data=(); rex="^application/lang/ui/(.*?).php$"
    for file in $files; do
      if [[ "$file" =~ $rex ]]; then
        l10n_data["$(echo $file | sed -E "s~$rex~\1~")"]="$file"
      fi
    done

    # If NO localization data files were changed for $fraction
    if [[ "${#l10n_data[@]}" -eq 0 ]]; then
      echo "no locale data was changed" | prepend "» "

    # Else add to the pending migration list and print status
    else
      # Foreach changed locale file
      for lang in "${!l10n_data[@]}"; do
        migrate["$fraction"]+="lang/import/data?$fraction:$lang "
      done
      echo "locale data changes for ${#l10n_data[@]} language(s) detected" | prepend "» "
    fi
  done

  # If at least one system and/or custom migration detected
  if [[ ${#migrate[@]} -gt 0 ]]; then

    # Remove local database dump, if any, to prevent duplicate disk space usage
    rm -f data/dump.sql.gz*

    # Create pre-migrate database backup, if not yet created
    if [[ ! -d data/before ]]; then
      echo -e "Backing up the current database state locally before running migrations:"
      echo -ne "${gray}"
      source maintain/dump-prepare.sh "data/before" "» "
      echo -ne "${d}"

    # Else restore database from pre-migrate backup:
    # 1.Stop maxwell and/or closetab php processes if any running
    # 2.Shut down mysql server, clean it's data/ dir and start back
    # 3.Import each (possibly chunked) dump
    # 4.Run maxwell-specific sql
    # 5.If maxwell and/or closetab php processes were running - enable back
    else
      echo -e "Restoring database from pre-migrate backup:"
      restore_dump_from_local "data/before" "» "
    fi

    # Foreach fraction as a key within $migrate array
    for fraction in "${!migrate[@]}"; do

      # Print status
      echo "Running migrations for $fraction fraction:"

      # Foreach migration action
      for action in ${migrate["$fraction"]}; do

        # Prepare and print msg, change dir to webroot, run migration action and change dir back
        local msg=" - ${g}php indi ${action}${d} ..."; echo -e "$msg"
        cd "custom"
        set +e; php indi $action 2>&1 | prepend "     " true; exit_code=$?; set -e
        cd "../"

        # If migration failed
        if [[ $exit_code -ne 0 ]]; then

          # Return failure exit code
          echo "Database migration step has failed during update. In this situation you can"
          echo "either run 'source restore dump before' command to get back to the pre-migration"
          echo "(i.e. original) database state, or try to re-run the migration step again with"
          echo "'source update' command - make sense if failure is investigated and fixed."
          return $exit_code

        # Else is no lines were printed by migration action
        elif [[ $(prepended) -eq 0 ]]; then

          # Rewrite msg now with trailing 'Done'
          clear_last_lines 1; echo -e "$msg Done"

        # Else print Done (with indent) as the next line after the lines printed by migration action
        else
          echo "   Done"
        fi
      done
    done
  fi

  # Foreach fraction
  for fraction in system custom; do

    # Setup fraction repo folder
    if [[ "$fraction" == "system" ]]; then
      folder="$VDR/system"
    else
      folder="custom"
    fi

    # Spoof existing migration commit with the most recent one
    # to be able to distinguish between old and new migrations
    set_migration_commit "$fraction" "$(git -C "$folder" rev-parse HEAD)"
  done

  # If at least one system and/or custom migration detected - remove data/before folder
  if [[ ${#migrate[@]} -gt 0 ]]; then
    rm -rf data/before
  fi
}

# Print quantity of lines prepended by the last piping of some command's output into prepend() function
prepended() {
  cat "$DOC/var/prepended"
  rm "$DOC/var/prepended"
}

# Get the value of given variable from .env file
get_env() {
  local chars=0; [[ "$1" = "GH_TOKEN_SYSTEM_RO" ]] && chars=44;
  grep "^$1=" .env | cut -d '=' -f 2- | sed 's/^"//; s/"$//' | trim "$chars"
}

# Search .env file for a given variable and update it's value with  a given one
set_env() {

  # Arguments
  local name="$1"
  local value="$2"

  # Do update in .env file
  if [[ "$value" =~ [[:space:]] ]]; then
    sed -i 's~^'"$name"'=.*$~'"$name"'="'"$value"'"~' .env
  else
    sed -i 's~^'"$name"'=.*$~'"$name"'='"$value"'~' .env
  fi

  # Replace in current bash environment
  export "$name"="$value"
}

# Get the comment for a variable
# Usage: get_env_comment_raw VAR [FILE]
get_env_tip() {

  # Arguments
  local var="$1"
  local file="${2:-.env}"

  # Get comment
  awk -v var="$var" '
    # Collect consecutive comment lines (preserve exactly)
    /^#/ { buf[++n] = $0; next }

    # If a blank or whitespace-only line appears, the block is no longer adjacent
    /^[[:space:]]*$/ { n = 0; split("", buf); next }

    # When we hit the target variable at column 1, print buffered comments and exit
    $0 ~ "^" var "=" {
        for (i = 1; i <= n; i++) print buf[i]
        exit
    }

    # Any other non-comment line clears the buffer
    { n = 0; split("", buf) }
  ' "$file"
}

# Prompt for GIT_COMMIT_NAME and/or GIT_COMMIT_EMAIL if any missing
prompt_git_commit_identify_if_missing() {
  prompt_env "GIT_COMMIT_NAME" "git config user.name"
  prompt_env "GIT_COMMIT_EMAIL" "git config user.email"
}

# Prompt for a certain variable if it has empty value in .env, and optionally run callback command
prompt_env() {

  # Arguments
  local env="$1"
  local cmd="$2"

  # If missing in .env
  if [[ "$(get_env "$env")" == "" ]]; then

    # If we're here due to call from Flask and ${!env} variable is given from there as well - use it
    if [[ ! -z "${FLASK_APP:-}" && ! -z "${!env}" ]]; then
      set_env "$env" "${!env}"

    # Else prompt for it
    else
      echo
      read_text true "$env" true true
    fi

    # Run callback
    [[ "$cmd" != "" ]] && $cmd "${!env}"
  fi
}

# Trim last X chars from the piped string
trim() {
  local n="${1:-0}"
  sed "s/.\{$n\}$//"
}