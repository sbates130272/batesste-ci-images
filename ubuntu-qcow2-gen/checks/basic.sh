# shellcheck shell=bash
#
# Assertions run inside the "basic" guest during the build's probe boot.
# Appended to a "set -eu" bash script, so any failing command fails the build.

# The catalogue defaults to Ubuntu 26.04 (Linux 7.0). Compare the whole version
# tuple, not major-and-minor separately: "major >= 6 and minor >= 18" rejects
# 7.0, which is the most likely way a correct image still looks wrong.
test "$(printf '6.18\n%s\n' "$(uname -r)" | sort -V | head -1)" = "6.18"

# The contract every consumer relies on.
sudo -n true
test -d /lib/modules/"$(uname -r)"/build
command -v gcc make cmake ninja dkms git
test "$(df --output=avail -BG / | tail -1 | tr -dc 0-9)" -ge 20
