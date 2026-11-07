#!/bin/bash
# Quits StayOn (which restores normal sleep if StayOn turned it off) and removes it.
# If the lid is closed and StayOn is holding the Mac awake, the Mac will sleep.
set -uo pipefail

pkill -TERM -x StayOn 2>/dev/null
rm -rf /Applications/StayOn.app "$HOME/Applications/StayOn.app"
rm -rf "$HOME/Library/Application Support/StayOn"

if [[ -e /etc/sudoers.d/stayon ]]; then
  echo "Removing the StayOn sudo rule (asks for your password):"
  sudo rm -f /etc/sudoers.d/stayon
fi
echo "StayOn removed."
