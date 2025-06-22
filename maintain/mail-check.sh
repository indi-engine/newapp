#!/bin/bash

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
