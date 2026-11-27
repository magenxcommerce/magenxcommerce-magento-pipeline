#!/bin/bash
# Push a release archive to an OCI registry the way magenx-deputy-go (deploy.source: oci) reads it:
# one image manifest whose only layer is the archive itself, so the layer digest is the archive's sha256
# (the sha256 deputy checks), annotated org.opencontainers.image.version=<tag> and signed with cosign.
# Idempotent: a tag that already holds the archive is not pushed again, a signature that verifies is kept.
#
# Environment: OCI_REPOSITORY (registry/owner/name), TAG_NAME, ARCHIVE (path), SHA256 (hex),
#   COSIGN_PRIVATE_KEY, COSIGN_PASSWORD. Needs crane, cosign and jq on PATH and a registry login
#   (crane auth login) that cosign shares through ~/.docker/config.json.
# Prints the manifest digest; writes manifest-digest to GITHUB_OUTPUT when set.
set -euo pipefail

die() { echo "::error::$*" >&2; exit 1; }

: "${OCI_REPOSITORY:?}" "${TAG_NAME:?}" "${ARCHIVE:?}" "${SHA256:?}"
[ -n "${COSIGN_PRIVATE_KEY:-}" ] || die "secret COSIGN_PRIVATE_KEY is not set: deputy only deploys signed releases"

ref="${OCI_REPOSITORY}:${TAG_NAME}"
layer="sha256:${SHA256}"
annotation="org.opencontainers.image.version"

actual="sha256:$(sha256sum "${ARCHIVE}" | cut -d' ' -f1)"
[ "${actual}" = "${layer}" ] || die "${ARCHIVE} is ${actual}, expected ${layer}"

# "<layers> <first layer digest> <version annotation>" of the tag, empty when the tag does not exist
state() {
  crane manifest "${ref}" 2> /dev/null \
    | jq -r --arg a "${annotation}" '"\(.layers | length) \(.layers[0].digest) \(.annotations[$a] // "")"' \
    || true
}
want="1 ${layer} ${TAG_NAME}"

if [ "$(state)" = "${want}" ]; then
  echo "${ref} already holds the archive"
else
  # the archive is the layer as it is (gzip tar), no second compression
  crane append --oci-empty-base -f "${ARCHIVE}" -t "${ref}" > /dev/null
  crane mutate --annotation "${annotation}=${TAG_NAME}" -t "${ref}" "${ref}" > /dev/null
  [ "$(state)" = "${want}" ] || die "${ref} does not hold the archive as its only layer after the push: $(state)"
  echo "pushed ${ref}"
fi
digest="$(crane digest "${ref}")"
signed="${OCI_REPOSITORY}@${digest}"

tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT
# no transparency log: a private release is not published to the public Rekor log
echo '{"mediaType":"application/vnd.dev.sigstore.signingconfig.v0.2+json","rekorTlogConfig":{},"tsaConfig":{}}' \
  > "${tmp}/signing-config.json"
cosign public-key --key env://COSIGN_PRIVATE_KEY > "${tmp}/cosign.pub" \
  || die "COSIGN_PRIVATE_KEY or COSIGN_PASSWORD is wrong"
verify=(--key "${tmp}/cosign.pub" --insecure-ignore-tlog=true)
if cosign verify "${verify[@]}" "${signed}" > /dev/null 2>&1 < /dev/null; then
  echo "${signed}: signature exists"
else
  cosign sign --yes --key env://COSIGN_PRIVATE_KEY --signing-config "${tmp}/signing-config.json" "${signed}" < /dev/null
  cosign verify "${verify[@]}" "${signed}" > /dev/null < /dev/null || die "signature of ${signed} does not verify"
  echo "${signed}: signed"
fi

echo "${digest}"
[ -z "${GITHUB_OUTPUT:-}" ] || echo "manifest-digest=${digest}" >> "${GITHUB_OUTPUT}"
