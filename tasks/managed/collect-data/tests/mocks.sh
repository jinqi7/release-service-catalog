#!/usr/bin/env bash
set -eux

# mocks to be injected into task step scripts
curl() {
  # Output the call to stderr
  echo "Mock curl called with:" "$@" >&2
  echo "$@" >> "$(params.dataDir)/mock_curl.txt"
  echo '{ "sha": "12345"}'
}

merge-json1() {
  # Store the JSON strings in variables
  json1="$1"
  json2="$2"

  # Validate JSON input
  if ! echo "$json1" | jq -e . >/dev/null 2>&1; then
    echo "Error: Invalid JSON in parameter 1"
    exit 1
  fi

  if ! echo "$json2" | jq -e . >/dev/null 2>&1; then
    echo "Error: Invalid JSON in parameter 2"
    exit 1
  fi

  # Merge the JSON objects recursively, combining arrays and replacing other values
  merged_json=$(printf '%s\n%s' "$json1" "$json2" | jq -cs '
  def merge_objects(a; b):
    a as $a | b as $b |
    ($a | keys) + ($b | keys) | unique | map({
      key: .,
      value: (
        if ($a[.] | type) == "object" and ($b[.] | type) == "object" then
          merge_objects($a[.]; $b[.])
        elif ($a[.] | type) == "array" and ($b[.] | type) == "array" then
	  ($a[.] + $b[.]) | unique
        else
          $b[.] // $a[.]
        end
      )
    }) | from_entries;

  .[0] as $first | .[1] as $second | merge_objects($first; $second)
  ')
  # Print the merged JSON
  echo "$merged_json"
}
