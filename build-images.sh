#!/bin/bash

#
# Copyright (C) 2023 Nethesis S.r.l.
# SPDX-License-Identifier: GPL-3.0-or-later
#

# Terminate on error
set -e

# Prepare variables for later use
images=()
# The image will be pushed to GitHub container registry
repobase="${REPOBASE:-ghcr.io/platypuschan}"
# Keep the published image name aligned with module-info.yml, which derives
# "matrix-discord-bridge" from the repository name "ns8-matrix-discord-bridge".
reponame="matrix-discord-bridge"
repository_source="${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-Platypuschan/ns8-matrix-discord-bridge}"
# The bridge itself is built and published by
# github.com/Platypuschan/discord-matrix-voice: every tested commit on its
# main branch is pushed as discord-matrix-voice:<first 12 digits of the
# commit>, and those tags are never overwritten. NS8 passes the image to the
# module as DISCORD_MATRIX_VOICE_IMAGE. Raise CATALOG_VERSION when changing it.
bridge_image="ghcr.io/platypuschan/discord-matrix-voice:bc5c19d7d62c"
# Keep in sync with the Node.js version used by .github/workflows/validate.yml
NODE_IMAGE="docker.io/library/node:24.20.0"
nodebuilder="nodebuilder-matrix-discord-bridge-${NODE_IMAGE##*:}"
# Create a new empty container image
container=$(buildah from scratch)

# Reuse an existing builder container for the same Node.js version, to speed up builds
if ! buildah containers --format "{{.ContainerName}}" | grep -qx "${nodebuilder}"; then
	echo "Pulling NodeJS runtime..."
	buildah from --name "${nodebuilder}" -v "${PWD}:/usr/src:Z" "${NODE_IMAGE}"
fi

echo "Build static UI files with node..."
buildah run \
	--workingdir=/usr/src/ui \
	"${nodebuilder}" \
	sh -c "corepack enable && yarn install --immutable && yarn build"

# Add imageroot directory to the container image
buildah add "${container}" imageroot /imageroot
buildah add "${container}" ui/dist /ui
# Declare the pinned bridge image, a range of 8 UDP ports for call media
# (opened in the firewall, hence node:fwadm; the bridge's WebRTC stack
# needs one port per local address plus one for TURN, and rejects a range
# of a single port) and a rootless container. No web route: the bridge has
# no HTTP interface.
# IMAGETAG overrides the published module tag (latest by default).
buildah config --entrypoint=/ \
	--label="org.opencontainers.image.source=${repository_source}" \
	--label="org.opencontainers.image.revision=${GITHUB_SHA:-$(git rev-parse HEAD 2>/dev/null || echo unknown)}" \
	--label="org.nethserver.authorizations=node:fwadm" \
	--label="org.nethserver.udp-ports-demand=8" \
	--label="org.nethserver.rootfull=0" \
	--label="org.nethserver.images=${bridge_image}" \
	"${container}"
# Commit the image
buildah commit "${container}" "${repobase}/${reponame}"

# Append the image URL to the images array
images+=("${repobase}/${reponame}")

#
# Setup CI when pushing to Github.
# Warning! docker::// protocol expects lowercase letters (,,)
if [[ -n "${CI}" ]]; then
	# Set output value for Github Actions
	printf "images=%s\n" "${images[*],,}" >>"${GITHUB_OUTPUT}"
else
	# Just print info for manual push
	printf "Publish the images with:\n\n"
	for image in "${images[@],,}"; do printf "  buildah push %s docker://%s:%s\n" "${image}" "${image}" "${IMAGETAG:-latest}"; done
	printf "\n"
fi
