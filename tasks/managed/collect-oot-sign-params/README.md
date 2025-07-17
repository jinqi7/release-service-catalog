# collect-oot-sign-params

Tekton task that collects configuration settings for the OOT kernel modules signing from the data file

## Parameters

| Name                    | Description                                                                                                                | Optional | Default value           |
|-------------------------|----------------------------------------------------------------------------------------------------------------------------|----------|-------------------------|
| dataPath                | Path to the JSON string of the merged data containing the pyxis configuration options to use                               | No       | -                       |
| snapshotPath            | Path to the JSON string of the mapped Snapshot spec in the data workspace                                                  | No       | -                       |
| ociStorage              | The OCI repository where the Trusted Artifacts are stored                                                                  | Yes      | empty                   |
| ociArtifactExpiresAfter | Expiration date for the trusted artifacts created in the OCI repository. An empty string means the artifacts do not expire | Yes      | 1d                      |
| trustedArtifactsDebug   | Flag to enable debug logging in trusted artifacts. Set to a non-empty string to enable                                     | Yes      | ""                      |
| orasOptions             | oras options to pass to Trusted Artifacts calls                                                                            | Yes      | ""                      |
| sourceDataArtifact      | The Trusted Artifact URI pointing to the artifact with the application snapshot spec and the release data                  | Yes      | ""                      |
| dataDir                 | The location where data will be stored                                                                                     | Yes      | $(workspaces.data.path) |
| taskGitUrl              | The url to the git repo where the release-service-catalog tasks to be used are stored                                      | No       | -                       |
| taskGitRevision         | The revision in the taskGitUrl repo to be used                                                                             | No       | -                       |
