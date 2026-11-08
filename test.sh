#!/bin/bash
# End-to-end test of StayOn's on/off logic using a TESTMODE build.
# The build runs fake pmset and sudo scripts from a temp folder, so the real sleep
# setting is never changed. The script also checks that at the end.
set -uo pipefail
cd "$(dirname "$0")"

ROOT="$(mktemp -d)"
BIN="$ROOT/StayOn-test"
swiftc -swift-version 5 -D TESTMODE StayOn.swift -o "$BIN" || exit 1

cat > "$ROOT/pmset" <<EOF
#!/bin/bash
case "\$*" in
  -g) printf ' SleepDisabled\t\t%s\n' "\$(cat "$ROOT/state")" ;;
  "-a disablesleep 0") echo 0 > "$ROOT/state"; echo off >> "$ROOT/calls" ;;
  "-a disablesleep 1") echo 1 > "$ROOT/state"; echo on >> "$ROOT/calls" ;;
  displaysleepnow) echo display >> "$ROOT/calls" ;;
  sleepnow) echo sleepnow >> "$ROOT/calls" ;;
  *) echo "unexpected: \$*" >> "$ROOT/calls"; exit 1 ;;
esac
EOF
cat > "$ROOT/sudo" <<EOF
#!/bin/bash
[[ -e "$ROOT/sudo_denied" ]] && exit 1
shift
exec "\$@"
EOF
chmod +x "$ROOT/pmset" "$ROOT/sudo"

REAL_BEFORE="$(/usr/bin/pmset -g | grep SleepDisabled)"
PASS=0; FAIL=0; PID=""

ok() { PASS=$((PASS + 1)); echo "  ok    $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL  $1 (state=$(cat "$ROOT/state") ui=$(cat "$ROOT/ui" 2>/dev/null) marker=$([[ -e "$ROOT/support/on" ]] && echo yes || echo no))"; }

# Polls until the condition is true, for up to 8 seconds.
expect() { # description condition
  local i
  for ((i = 0; i < 80; i++)); do
    if eval "$2"; then ok "$1"; return; fi
    perl -e 'select(undef,undef,undef,0.1)'
  done
  bad "$1"
}
# Confirms the condition stays true: gives the app time to do the wrong thing.
holds() { # description condition
  perl -e 'select(undef,undef,undef,2.5)'
  if eval "$2"; then ok "$1"; else bad "$1"; fi
}

state_is() { [[ "$(cat "$ROOT/state")" == "$1" ]]; }
ui_is() { [[ "$(cut -d'|' -f1 "$ROOT/ui" 2>/dev/null)" == "$1" ]]; }
marker() { [[ -e "$ROOT/support/on" ]]; }
no_marker() { [[ ! -e "$ROOT/support/on" ]]; }
is_on() { state_is 1 && ui_is on && marker; }
is_off() { state_is 0 && ui_is off && no_marker; }

reset() { # initial state
  stop
  rm -rf "$ROOT/support" "$ROOT/ui" "$ROOT/calls" "$ROOT/lid_closed" "$ROOT/sudo_denied" \
    "$ROOT/password_accepted" "$ROOT/confirm_turn_off" "$ROOT/failure_shown"
  echo "$1" > "$ROOT/state"
  echo boot-A > "$ROOT/boot"
  echo "90 power" > "$ROOT/battery"
  echo 0.7 > "$ROOT/brightness"
  touch "$ROOT/calls"
}
bright_is() { [[ "$(cat "$ROOT/brightness")" == "$1" ]]; }
no_saved_brightness() { [[ ! -e "$ROOT/support/brightness" ]]; }
start() { STAYON_TEST_ROOT="$ROOT" "$BIN" >/dev/null 2>&1 & PID=$!; expect "app started" "[[ -e '$ROOT/ui' ]]"; }
stop() { [[ -n "$PID" ]] && { kill -TERM "$PID" 2>/dev/null; wait "$PID" 2>/dev/null; }; PID=""; }
crash() { kill -KILL "$PID"; wait "$PID" 2>/dev/null; PID=""; }
click() { kill -USR1 "$PID"; }

echo "One click on, one click off"
reset 0; start
expect "starts off" is_off
click; expect "click turns on" is_on
click; expect "second click turns off" is_off
holds "lid open: does not sleep the Mac" "! grep -q sleepnow '$ROOT/calls'"

echo "Lid closes while on"
reset 0; start; click; expect "on" is_on
touch "$ROOT/lid_closed"
expect "screen dims to black" "bright_is 0.0"
holds "Mac stays on with the lid closed" is_on
holds "display is never switched off (remote desktop keeps working)" "! grep -q display '$ROOT/calls'"
echo 0.4 > "$ROOT/brightness"
expect "dims again if macOS turns brightness up" "bright_is 0.0"
rm "$ROOT/lid_closed"
expect "lid opens: brightness restored" "bright_is 0.7 && no_saved_brightness"
holds "stays on when the lid opens" is_on

echo "Lid closes while off"
reset 0; start
touch "$ROOT/lid_closed"; holds "brightness untouched" "bright_is 0.7 && no_saved_brightness"

echo "Turning off with the lid closed asks first"
reset 0; start; click; expect "on" is_on
touch "$ROOT/lid_closed"; expect "dark" "bright_is 0.0"
click; holds "Keep On leaves it on" is_on
touch "$ROOT/confirm_turn_off"
click; expect "Turn Off turns it off" is_off
expect "and puts the Mac to sleep" "grep -q sleepnow '$ROOT/calls'"
rm "$ROOT/lid_closed"; expect "brightness restored when the lid opens" "bright_is 0.7"

echo "Quit with the lid closed"
reset 0; start; click; expect "on" is_on
touch "$ROOT/lid_closed"; expect "dark" "bright_is 0.0"
stop
expect "quitting restores brightness and sleep" "bright_is 0.7 && no_saved_brightness && state_is 0"
expect "and puts the Mac to sleep" "grep -q sleepnow '$ROOT/calls'"

echo "Crash with the lid closed"
reset 0; start; click; expect "on" is_on
touch "$ROOT/lid_closed"; expect "dark" "bright_is 0.0"
crash; start
holds "stays on and dark after relaunch" "is_on && bright_is 0.0"
rm "$ROOT/lid_closed"; expect "lid opens: brightness restored" "bright_is 0.7 && no_saved_brightness"

echo "Battery floor"
reset 0; start; click; expect "on" is_on
echo "11 battery" > "$ROOT/battery"; holds "stays on at 11%" is_on
echo "10 battery" > "$ROOT/battery"; expect "turns off at 10%" is_off
expect "says why" "grep -q 'battery reached 10%' '$ROOT/ui'"

echo "Battery floor with the lid closed"
reset 0; start; click; expect "on" is_on
touch "$ROOT/lid_closed"; echo "10 battery" > "$ROOT/battery"
expect "turns off and puts the Mac to sleep" "is_off && grep -q sleepnow '$ROOT/calls'"

echo "Battery floor is ignored on the charger"
reset 0; start; click; expect "on" is_on
echo "5 power" > "$ROOT/battery"; holds "stays on at 5% while charging" is_on

echo "Turning on below the floor is respected, once"
reset 0; echo "8 battery" > "$ROOT/battery"; start; click; expect "on at 8%" is_on
holds "does not turn itself off" is_on
echo "30 battery" > "$ROOT/battery"; holds "still on after charging to 30%" is_on
echo "9 battery" > "$ROOT/battery"; expect "turns off on the next drop" is_off

echo "Crash keeps the session"
reset 0; start; click; expect "on" is_on
crash; start
expect "still on after relaunch" is_on
holds "sleep was not touched" "! tail -n +2 '$ROOT/calls' | grep -q off"

echo "Restart ends the session"
reset 0; start; click; expect "on" is_on
crash; echo boot-B > "$ROOT/boot"; start
expect "off after a restart" is_off

echo "Quit restores sleep"
reset 0; start; click; expect "on" is_on
stop
expect "sleep is back on" "state_is 0 && no_marker"

echo "Quit leaves another app's hold alone (Insomnia)"
reset 1; start
expect "shows the real setting" "ui_is on && no_marker"
stop
holds "sleep setting is unchanged" "state_is 1 && ! grep -q off '$ROOT/calls'"

echo "Safety limits leave another app's hold alone"
reset 1; echo "5 battery" > "$ROOT/battery"; start
holds "does not turn off a hold it does not own" "state_is 1 && ui_is on"

echo "Another app turns sleep back on"
reset 0; start; click; expect "on" is_on
echo 0 > "$ROOT/state"
expect "icon follows and marker clears" is_off

echo "No permission yet"
reset 0; touch "$ROOT/sudo_denied" "$ROOT/password_accepted"; start
click; expect "password accepted: turns on" is_on
reset 0; touch "$ROOT/sudo_denied"; start
click; expect "password cancelled: reports failure" "[[ -e '$ROOT/failure_shown' ]]"
expect "password cancelled: stays off" is_off

stop
REAL_AFTER="$(/usr/bin/pmset -g | grep SleepDisabled)"
echo "Real Mac"
if [[ "$REAL_BEFORE" == "$REAL_AFTER" ]]; then ok "real sleep setting unchanged"; else bad "real sleep setting changed"; fi
rm -rf "$ROOT"
defaults delete StayOn-test >/dev/null 2>&1

echo
echo "$PASS passed, $FAIL failed"
[[ "$FAIL" == 0 ]]
