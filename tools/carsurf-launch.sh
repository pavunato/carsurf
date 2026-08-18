#!/bin/sh
# carsurf-launch — open an app on the CarPlay display from a shell.
#
#   carsurf-launch com.google.ios.youtubemusic
#
# uiopen(1) launches on the phone; nothing shipped by the system can target the
# car screen. This writes the bundle identifier where CSCarLaunch.m reads it and
# posts the notification that makes the CarPlay host run DashBoard's own
# activation — the same path an icon tap takes.
#
# The app must already be enabled in CarSurf, and a vehicle must be connected.
# Results land in the shared log: carsurf-logs | grep carlaunch

set -e

if [ $# -ne 1 ]; then
    echo "usage: carsurf-launch <bundle-id>" >&2
    exit 2
fi

# Same candidate order as CSConfig's relay, so rootless and rootful installs
# both land on the directory the tweak actually reads.
for dir in /var/jb/Library/CarSurf /Library/CarSurf; do
    if [ -d "$dir" ]; then
        REQUEST="$dir/carlaunch"
        break
    fi
done

if [ -z "$REQUEST" ]; then
    echo "carsurf-launch: no CarSurf relay directory; is the tweak installed?" >&2
    exit 1
fi

# Written before the post, and world-readable: the CarPlay host runs as mobile.
printf '%s\n' "$1" > "$REQUEST"
chmod 644 "$REQUEST"

# By path, not by name: /usr/local/bin is not on the default device PATH.
"$(dirname "$0")/carsurf-notify" com.pavunato.carsurf/carlaunch >/dev/null
echo "requested $1 on the CarPlay display"
