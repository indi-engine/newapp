#!/bin/bash

# If EMAIL_SENDER_DOMAIN variable is not empty - print DNS-records that are required
# to be added into settings of each domain mentioned in that variable
if [[ ! -z "$EMAIL_SENDER_DOMAIN" ]]; then

  # Detect our external IP address
  addr=$(wget -qO- http://ipecho.net/plain)

  # Header line shortcut
  line0="Type\tName\tData"

  # Split LETS_ENCRYPT_DOMAIN into an array
  IFS=' ' read -r -a senders <<< "$EMAIL_SENDER_DOMAIN"

  # Iterate over each domain for postfix and opendkim configuration
  for maildomain in "${senders[@]}"; do

    # Print the message for distinction between the records for different domains
    echo ""
    echo "DNS-records required to be added for $maildomain:"
    echo ""

    # Get DKIM-key
    dkim=$(cat /etc/opendkim/keys/$maildomain/mail.txt)

    # Strip everything except the key value itself
    dkim=$(echo "$dkim" | sed -E 's~"~~g' | tr -d '\n' | grep -oP 'v=DKIM[^)]+' | sed -E 's~\s{2,}~ ~g')

    # Prepare lines
    line1="MX\t@\tblackhole.io"
    line2="TXT\t@\tv=spf1 a mx ip4:$addr ~all"
    line3="TXT\t_dmarc\tv=DMARC1; p=none"
    line4="TXT\tmail._domainkey\t$dkim"

    # Display the data as a table
    echo -e "$line0\n$line1\n$line2\n$line3\n$line4" | column -t -s $'\t'

  done
  echo ""
  echo "NOTE: If you already have MX-record existing in your DNS-settings - then don't add the one mentioned above"
  echo "NOTE: If you already have TXT-record having Data starting with 'v=spf1' - then amend the existing record to append new IP to the existing one, e.g. 'ip4:<existing-ip> ip4:$addr'"
  echo ""
else
  echo "No domain names were specified in \$EMAIL_SENDER_DOMAIN variable"
fi
