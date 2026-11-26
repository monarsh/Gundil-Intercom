#!/bin/sh
# Makes the release signing key, once, on your own computer. Nothing is
# uploaded: you add the two values to GitHub yourself.
#
#   tool/make_release_key.sh [FOLDER]     (default: ~/gundil-release-key)
#
# Then, in the repository on GitHub, Settings > Secrets and variables >
# Actions:
#   Secrets   > New repository secret:   GUNDIL_RELEASE_SIGNING_KEY = the
#               whole content of release-signing-key.pem (BEGIN … END lines)
#   Variables > New repository variable: GUNDIL_RELEASE_KEY = the public key
#               this script prints
#
# Keep release-signing-key.pem offline as a backup (e.g. a USB stick in a
# drawer) and delete it from this computer. If it is lost, make a new key:
# apps built with the old public key then need one update installed by hand.
set -eu
DIR=${1:-$HOME/gundil-release-key}
KEY=$DIR/release-signing-key.pem
if [ -e "$KEY" ]; then
	echo "$KEY exists already; not replacing it."
	exit 1
fi
mkdir -p "$DIR"
chmod 700 "$DIR"
umask 077
openssl ecparam -name prime256v1 -genkey -noout -out "$KEY"
PUB=$(openssl ec -in "$KEY" -pubout -outform DER 2>/dev/null | tail -c 65 | base64 | tr -d '\n')
printf '%s\n' "$PUB" > "$DIR/release-key.pub.txt"
cat <<EOF
Made the release signing key:
  private: $KEY   (secret: never share, never commit)
  public:  $PUB

On GitHub, Settings > Secrets and variables > Actions:
  1. Secrets   > New repository secret
       Name:  GUNDIL_RELEASE_SIGNING_KEY
       Value: the whole content of $KEY
  2. Variables > New repository variable
       Name:  GUNDIL_RELEASE_KEY
       Value: $PUB

Then keep a backup of $KEY offline and delete it from this computer.
EOF
