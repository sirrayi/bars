#!/bin/sh -p
# -p blocks inherited functions and startup hooks before validation; it does not elevate privileges.
set -eu

APP="/Applications/bars.app"
HELPER="$APP/Contents/Helpers/BarsCLI"

if [ ! -x "$HELPER" ]; then
  /bin/echo "BarsCLI helper not found at $HELPER. Please reinstall bars." >&2
  exit 1
fi

# Clear startup hooks and exported functions before entering the administrator shell.
/usr/bin/env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin /usr/bin/osascript - "$HELPER" <<'APPLESCRIPT'
on run argv
  set helperPath to item 1 of argv
  set installCommand to "set -eu" & linefeed & ¬
    "/bin/mkdir -p /usr/local/bin /opt/homebrew/bin" & linefeed & ¬
    "/bin/ln -sf " & quoted form of helperPath & " /usr/local/bin/bars" & linefeed & ¬
    "/bin/ln -sf " & quoted form of helperPath & " /opt/homebrew/bin/bars"

  do shell script installCommand with administrator privileges
end run
APPLESCRIPT

/bin/echo "bars CLI installed. Try: bars usage"
