#!/bin/sh
# Signs a release's checksums: DIR/SHA256SUMS.txt -> DIR/SHA256SUMS.txt.sig
# (ECDSA P-256 with SHA-256, DER), checked by the apps, the headless node
# and the gateway before they install an update (gateway/release_sig.go,
# packages/intercom_core/lib/src/update/release_signature.dart).
#
#   GUNDIL_RELEASE_SIGNING_KEY  the private key (PEM): GitHub secret
#   GUNDIL_RELEASE_KEY          its public key (base64): GitHub variable,
#                               built into every app
#
# Usage: tool/sign_release.sh DIR
set -eu
DIR=${1:?usage: sign_release.sh DIR}
SUMS=$DIR/SHA256SUMS.txt
[ -f "$SUMS" ] || { echo "No $SUMS" >&2; exit 1; }

if [ -z "${GUNDIL_RELEASE_SIGNING_KEY:-}" ]; then
	if [ -n "${GUNDIL_RELEASE_KEY:-}" ]; then
		echo "::error::The variable GUNDIL_RELEASE_KEY is set but the secret GUNDIL_RELEASE_SIGNING_KEY is missing: every app would refuse this release. Add the secret (tool/make_release_key.sh)." >&2
		exit 1
	fi
	echo "::warning::No release signing key (secret GUNDIL_RELEASE_SIGNING_KEY): this release is not signed."
	exit 0
fi

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
umask 077
printf '%s\n' "$GUNDIL_RELEASE_SIGNING_KEY" > "$T/key.pem"
openssl ec -in "$T/key.pem" -pubout -out "$T/pub.pem" 2>/dev/null ||
	{ echo "::error::GUNDIL_RELEASE_SIGNING_KEY is not a P-256 private key (PEM)." >&2; exit 1; }
PUB=$(openssl ec -in "$T/key.pem" -pubout -outform DER 2>/dev/null | tail -c 65 | base64 | tr -d '\n')
if [ -z "${GUNDIL_RELEASE_KEY:-}" ]; then
	echo "::warning::The variable GUNDIL_RELEASE_KEY is not set: the apps of this build don't check signatures. Set it to $PUB"
elif [ "$PUB" != "$GUNDIL_RELEASE_KEY" ]; then
	echo "::error::The signing key doesn't belong to GUNDIL_RELEASE_KEY (its public key is $PUB): every app would refuse this release." >&2
	exit 1
fi
openssl dgst -sha256 -sign "$T/key.pem" -out "$DIR/SHA256SUMS.txt.sig" "$SUMS"
openssl dgst -sha256 -verify "$T/pub.pem" -signature "$DIR/SHA256SUMS.txt.sig" "$SUMS" >/dev/null
echo "Signed $SUMS ($(wc -l < "$SUMS") files) -> SHA256SUMS.txt.sig"
