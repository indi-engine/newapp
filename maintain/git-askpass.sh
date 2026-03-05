#!/bin/bash

# If GH_TOKEN env is set, it means we're here due to git_askpass() calls
# called by 'source update' and/or 'source backup' command, so print that env
if env | grep -q GH_TOKEN=; then
  echo "${GH_TOKEN:-}"

# Else it means we're here due to manual 'git push' command, or another command that
# requires github auth. Anyway, here we use GH_TOKEN_CUSTOM_RW from .env, if given
else
  token="$(grep -E '^GH_TOKEN_CUSTOM_RW=[^[:space:]]' .env)"
  if [[ "$token" != "" ]]; then echo "${token#*=}"; else exit 1; fi
fi