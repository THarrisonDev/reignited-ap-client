#!/bin/sh
# Run the launcher's built-in installer from the native Linux launcher.
set -e
dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
if [ -x "$dir/srtap_launcher" ]; then
	exec "$dir/srtap_launcher" -install
fi
echo "srtap_launcher (Linux build) not found next to this script." >&2
exit 1
