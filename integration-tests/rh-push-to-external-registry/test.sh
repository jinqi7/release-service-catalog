#!/usr/bin/env bash
#
# --- Global Script Variables (Defaults) ---
CLEANUP="true"
NO_CVE="true" # Default to false

# Function to verify Release contents
# Relies on global variables: RELEASE_NAME, RELEASE_NAMESPACE, SUITE_DIR, managed_namespace
verify_release_contents() {
    echo "Verifying Release contents for ${RELEASE_NAME} in namespace ${RELEASE_NAMESPACE}..."
    local release_json
    release_json=$(kubectl get release/"${RELEASE_NAME}" -n "${RELEASE_NAMESPACE}" -ojson)
    if [ -z "$release_json" ]; then
        log_error "Could not retrieve Release JSON for ${RELEASE_NAME}"
    fi

    # get the oci artifact for the create-pyxis image so that we can get all the imageIds
    # created
    local pyxis_url="https://pyxis.preprod.api.redhat.com/"
    local managed_plr=$(jq -r '.status.managedProcessing?.pipelineRun' <<< "${release_json}")
    local managed_plr_name=$(cut -f2 -d/ <<< "${managed_plr}")

    local uri=$("${SCRIPT_DIR}/scripts/get-taskrun-result.sh" "${managed_plr_name}" "create-pyxis-image" \
        "sourceDataArtifact" "${managed_namespace}")
    local oci_artifact="${uri#*:}" # Assuming the URI might have a scheme like "oci:"
    echo "oci_artifact: ${oci_artifact}"

    local oci_artifact_dir=$(mktemp -d -p "$(pwd)")
    oras blob fetch "${oci_artifact}" --output - | tar -C "${oci_artifact_dir}" --no-overwrite-dir -zxmf -
    echo "Restored artifact ${ociArtifact} to ${oci_artifact_dir}"

    local failures=0
    local image_url image_arch

    image_url=$(jq -r '.status.artifacts.images[0]?.urls[0] // ""' <<< "${release_json}")
    image_arch=$(jq -r '.status.artifacts.images[0]?.arches[0] // ""' <<< "${release_json}")

    echo "Checking Image URL..."
    if [ -n "${image_url}" ]; then
        echo "✅️ image_url: ${image_url}"
    else
        echo "🔴 image_url was empty"
        failures=$((failures+1))
    fi
    echo "Checking Image Arch..."
    if [ -n "${image_arch}" ]; then
        echo "✅️ image_arch: ${image_arch}"
    else
        echo "🔴 image_arch was empty"
        failures=$((failures+1))
    fi

    echo "Checking Image IDs..."
    pyxisDataFile=$(find ${oci_artifact_dir} -name "pyxis.json")
    imageIds=$(jq -r '[.components[].pyxisImages[].imageId] | join(" ")' "${pyxisDataFile}")
    imageIdsFound=false

    # prepare pyxis credentials
    cert_secret_encoded_value=$(yq '. | select(.metadata.name | contains("pyxis-")) | .data.cert' ${SUITE_DIR}/resources/managed/secrets/managed-secrets.yaml)
    key_secret_encoded_value=$(yq '. | select(.metadata.name | contains("pyxis-")) | .data.key' ${SUITE_DIR}/resources/managed/secrets/managed-secrets.yaml)
    cert_secret_value=$(base64 -d <<< "${cert_secret_encoded_value}" > /tmp/cert)
    key_secret_value=$(base64 -d <<< "${key_secret_encoded_value}" > /tmp/key)

    for imageId in ${imageIds}; do
        result_image_json="$(curl --cert /tmp/cert --key /tmp/key ${pyxis_url}v1/images/id/${imageId})"
        result_image_id=$(jq -r '._id' <<< "${result_image_json}")
        if [ "${result_image_id}" == "${imageId}" ]; then
            echo "✅️ Found imageId: ${result_image_id} in pyxis"
        else
            echo "🔴 imageId: ${result_image_id} did not match expected imageId: ${imageId}"
            failures=$((failures+1))
        fi
        imageIdsFound=true
    done

    if [ "${imageIdsFound}" = false ]; then
        echo "🔴 imageIdsFound was false. No imageIds were found."
        failures=$((failures+1))
    fi

    if [ "${failures}" -gt 0 ]; then
      echo "🔴 Test has FAILED with ${failures} failure(s)!"
      exit 1
    else
      echo "✅️ All release checks passed. Success!"
    fi
}
