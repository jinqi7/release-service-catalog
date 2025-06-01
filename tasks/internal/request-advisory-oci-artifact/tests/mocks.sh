#!/usr/bin/env bash
set -ex

# mocks to be injected into task step scripts

function internal-request() {
  echo "InternalRequest 'abc-ir' created."
}

function kubectl() {
  # The IR won't actually be acted upon, so mock it to return Success as the task wants
  if [[ "$*" == "get internalrequest "*"-o=jsonpath={.status.results}" ]]
  then
    echo '{"result":"Success","advisory_oci_artifact":"oci:quay.io/konflux-ci/abc@sha256:a51f9ce8"}'
  else
    /usr/bin/kubectl $*
  fi
}
