#!/bin/bash
#
# Copyright (c) 2018-2021 Red Hat, Inc.
# This program and the accompanying materials are made
# available under the terms of the Eclipse Public License 2.0
# which is available at https://www.eclipse.org/legal/epl-2.0/
#
# SPDX-License-Identifier: EPL-2.0
#
# Updates plugin runner images to point a registry defined by environment
# variables
#     CHE_DEVFILE_IMAGES_REGISTRY_URL
#     CHE_DEVFILE_IMAGES_REGISTRY_ORGANIZATION
#     CHE_DEVFILE_IMAGES_REGISTRY_TAG
#
# By default, this script will operate on the `/var/www/html/devfiles` directory.
# This can be overridden by the environment variable $DEVFILES_DIR
#
# In addition, this script will perform the necessary set up for the offline
# devfile registry, replacing placeholders in all devfiles based off environment
# variable
#     CHE_DEVFILE_REGISTRY_URL
# which should be set to the public endpoint for this registry.
#
# Will execute any arguments on completion (`exec $@`)

set -e

REGISTRY=${CHE_DEVFILE_IMAGES_REGISTRY_URL}
ORGANIZATION=${CHE_DEVFILE_IMAGES_REGISTRY_ORGANIZATION}
TAG=${CHE_DEVFILE_IMAGES_REGISTRY_TAG}
PUBLIC_URL=${CHE_DEVFILE_REGISTRY_URL}
INTERNAL_URL=${CHE_DEVFILE_REGISTRY_INTERNAL_URL}

DEFAULT_DEVFILES_DIR="/var/www/html/devfiles"
DEVFILES_DIR="${DEVFILES_DIR:-${DEFAULT_DEVFILES_DIR}}"
INDEX_JSON="${DEVFILES_DIR}/index.json"

# Regex used to break an image reference into groups:
#   \1 - Whitespace and (optional) quotation preceding image reference
#   \2 - Registry portion of image, e.g. (quay.io)/eclipse/che-theia:tag
#   \3 - Organization portion of image, e.g. quay.io/(eclipse)/che-theia:tag
#   \4 - Image name portion of image, e.g. quay.io/eclipse/(che-theia):tag
#   \5 - Optional image digest identifier (empty for tags), e.g. quay.io/eclipse/che-theia(@sha256):digest
#   \6 - Tag of image or digest, e.g. quay.io/eclipse/che-theia:(tag)
#   \7 - Optional quotation following image reference
IMAGE_REGEX='([[:space:]]*"?)([._:a-zA-Z0-9-]*)/([._a-zA-Z0-9-]*)/([._a-zA-Z0-9-]*)(@sha256)?:([._a-zA-Z0-9-]*)("?)'

# Extract and use env variables with image digest information.
# Env variable name format: 
# RELATED_IMAGES_(Image_name)_(Image_label)_(Encoded_base32_image_tag)
# Where are:
# "Image_name" - image name. Not valid chars for env variable name replaced to '_'.
# "Image_label" - image target, for example 'devfile_registry_image'.
# "Encoded_base32_image_tag_" - original image tag encoded to base32, to avoid invalid for env name chars. base32 alphabet has only 
# one invalid character for env name: '='. That's why it was replaced to '_'. 
# INFO: "=" for base32 it is pad character. If encoded string contains this char(s), then it is always located at the end of the string.
# Env value it is image with digest to use.
# Example env variable:
# RELATED_IMAGE_che_rust_1_39_devfile_registry_image_G4XDCMZOGIFA____=quay.io/eclipse/che-rust-1.39@sha256:3d9f36e6b3ed99c7a9959ac9476778ef5019add15b7c0f0b5f27b55587db3def
if env | grep -q ".*devfile_registry_image.*"; then
  declare -A imageMap
  readarray -t ENV_IMAGES < <(env | grep ".*devfile_registry_image.*")
  for imageEnv in "${ENV_IMAGES[@]}"; do
    tagOrDigest=$(echo "${imageEnv}" | sed -e 's;.*registry_image_\(.*\)=.*;\1;' | tr _ = | base32 -d)
    if [[ ${tagOrDigest} == *"@"* ]]; then
      # Well, image was "freezed", because it already has got digest, so do nothing.
      continue
    fi
    imageWithDigest=${imageEnv#*=};
    if [[ -n "${tagOrDigest}" ]]; then
      imageToReplace="${imageWithDigest%@*}:${tagOrDigest}"
    else
      imageToReplace="${imageWithDigest%@*}"
    fi
    digest="@${imageWithDigest#*@}"
    imageMap["${imageToReplace}"]="${digest}"
  done

  echo "--------------------------Digest map--------------------------"
  for KEY in "${!imageMap[@]}"; do
    echo "Key: $KEY Value: ${imageMap[${KEY}]}"
  done
  echo "--------------------------------------------------------------"

  readarray -t devfiles < <(find "${DEVFILES_DIR}" -name 'devfile.yaml')
  for devfile in "${devfiles[@]}"; do
    readarray -t images < <(grep "image:" "${devfile}" | sed -r "s;.*image:[[:space:]]*'?\"?([._:a-zA-Z0-9-]*/?[._a-zA-Z0-9-]*/[._a-zA-Z0-9-]*(@sha256)?:?[._a-zA-Z0-9-]*)'?\"?[[:space:]]*;\1;")
    for image in "${images[@]}"; do
      separators="${image//[^\/]}"
      # Warning, keep in mind: image without registry name is it possible case. It's mean, that image comes from private registry, where is we have organization name, but no registry name...
      digest="${imageMap[${image}]}"

      if [[ -z "${digest}" ]] && [ "${#separators}" == "1" ]; then
        imageWithDefaultRegistry="sds.redii.net/${image}"
        digest="${imageMap[${imageWithDefaultRegistry}]}"
      fi

      if [[ -n "${digest}" ]]; then
        if [[ ${image} == *":"* ]]; then
          imageWithoutTag="${image%:*}"
          tag="${image#*:}"
        else
          imageWithoutTag=${image}
          tag=""
        fi

        REGEX="([[:space:]]*\"?'?)(${imageWithoutTag}):?(${tag})(\"?'?)"
        sed -i -E "s|image:${REGEX}|image:\1\2${digest}\4|" "${devfile}"
      fi
    done
  done
fi

# We can't use the `-d` option for readarray because
# registry.centos.org/centos/httpd-24-centos7 ships with Bash 4.2
# The below command will fail if any path contains whitespace
readarray -t files < <(find "${DEVFILES_DIR}" -name 'devfile.yaml' -o -name 'meta.yaml' -o -name 'devworkspace-che-*.yaml')
for file in "${files[@]}"; do
  echo "Checking files $file"
  # Need to update each field separately in case they are not defined.
  # Defaults don't work because registry and tags may be different.
  
  echo "    change repository and image in multiline"
  if [ -n "$REGISTRY" ]; then
    echo "    Updating image registry to $REGISTRY"
    sed -i -E "s|image:$IMAGE_REGEX|image:\1${REGISTRY}/\3/\4\5:\6\7|g" "$file"
  fi
  if [ -n "$ORGANIZATION" ]; then
    echo "    Updating image organization to $ORGANIZATION"
    sed -i -E "s|image:$IMAGE_REGEX|image:\1\2/${ORGANIZATION}/\4\5:\6\7|g" "$file"
  fi
  if [ -n "$TAG" ]; then
    echo "    Updating image tag to $TAG"
    sed -i -E "s|image:$IMAGE_REGEX|image:\1\2/\3/\4:${TAG}\7|g" "$file"
  fi
  sed -i -E "s|image:.*/.*/|image: sds.redii.net/ide-dev/|g" "$file"
done

if [ -n "$INTERNAL_URL" ]; then
  INTERNAL_URL=${INTERNAL_URL%/}
  echo "Updating internal URL in files to ${INTERNAL_URL}"
  sed -i "s|{{ INTERNAL_URL }}|${INTERNAL_URL}|" "${files[@]}" "$INDEX_JSON"
fi

if [ -n "$PUBLIC_URL" ]; then
  echo "Updating devfiles to point at internal project zip files"
  PUBLIC_URL=${PUBLIC_URL%/}
  sed -i "s|{{ DEVFILE_REGISTRY_URL }}|${PUBLIC_URL}|" "${files[@]}" "$INDEX_JSON"

  # Add PUBLIC_URL at the begining of 'icon' field and links ('self', 'eclipse/che-theia/latest' and 'eclipse/che-theia/next')
  sed -i "s|\"icon\": \"/images/|\"icon\": \"${PUBLIC_URL}/images/|" "$INDEX_JSON"
  sed -i "s|\"self\": \"/devfiles/|\"self\": \"${PUBLIC_URL}/devfiles/|" "$INDEX_JSON"
  sed -i "s|\"eclipse/che-theia/latest\": \"/devfiles/|\"eclipse/che-theia/latest\": \"${PUBLIC_URL}/devfiles/|" "$INDEX_JSON"
  sed -i "s|\"eclipse/che-theia/next\": \"/devfiles/|\"eclipse/che-theia/next\": \"${PUBLIC_URL}/devfiles/|" "$INDEX_JSON"
  sed -i "s|\"che-incubator/che-code/insiders\": \"/devfiles/|\"che-incubator/che-code/insiders\": \"${PUBLIC_URL}/devfiles/|" "$INDEX_JSON"
else
  if grep -q '{{ DEVFILE_REGISTRY_URL }}' "${devfiles[@]}"; then
    echo "WARNING: environment variable 'CHE_DEVFILE_REGISTRY_URL' not configured" \
         "This may cause issues with importing projects in a workspace."
    # Experimental workaround -- detect service IP for che-devfile-registry
    # Depends on service used being named 'che-devfile-registry' and only works
    # within the cluster (i.e. browser-side retrieval won't work)
    SERVICE_HOST=$(env | grep DEVFILE_REGISTRY_SERVICE_HOST= | cut -d '=' -f 2)
    SERVICE_PORT=$(env | grep DEVFILE_REGISTRY_SERVICE_PORT= | cut -d '=' -f 2)
    URL="http://${SERVICE_HOST}:${SERVICE_PORT}"
    sed -i "s|{{ DEVFILE_REGISTRY_URL }}|${URL}|" "${files[@]}" "$INDEX_JSON"
  fi
fi

exec "${@}"
