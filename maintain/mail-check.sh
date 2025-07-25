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

  # If EMAIL_SENDER_DOMAIN variable is not empty
  if [[ ! -z "$EMAIL_SENDER_DOMAIN" ]]; then

    # Shortcuts
    sub="Test subject"
    msg="Test message"

    # Print what's going on
    echo ""
    echo "An attempt to send an email will now be done:"
    echo ""
    echo "Recepient: $GIT_COMMIT_EMAIL"
    echo "Subject: $sub"
    echo "Message: $msg"

    # Attempt to send test mail message at $GIT_COMMIT_EMAIL address
    echo -e "Subject: $sub\n\n$msg" | sendmail $GIT_COMMIT_EMAIL

    echo ""
    echo "Done, please check INBOX for that email address"

  # Else indicate configuration missing
  else
    echo "Value for \$EMAIL_SENDER_DOMAIN variable is missing in .env"
    echo "Set the value, re-create containers for apache and wrapper services, and try again"
  fi
fi