# regionaldr-with-virt

![Version: 0.1.4](https://img.shields.io/badge/Version-0.1.4-informational?style=flat-square)

A Helm chart to deploy RegionalDR configuration including virtualization

This chart provides a Regional DR configuration

## VM protection prerequisites

Do not protect VMs until the DRPolicy referenced by `drpc.drPolicyRef` is ready on the hub:

1. The `Validated` condition is `True`:

   ```bash
   oc get drpolicy 2m-vm -o jsonpath='{.status.conditions[?(@.type=="Validated")].status}'
   ```

2. `status.async.peerClasses` includes a non-empty `replicationID` for the virtualization storage class (`drpc.vmStorageClassName`, default `ocs-storagecluster-ceph-rbd-virtualization`).

The `drcluster-validation-<policy>` job (Argo CD sync-wave **8**) enforces these checks before the DRPlacementControl (sync-wave **10**) is applied. Without `replicationID` on the virtualization peer class, Ramen may route VM block PVCs to VolSync instead of async VolumeReplication.

When chart-owned DRClusters are created (`drCluster.create` or partner `ramen.infrastructureEnabled` with `resourcesEnabled: false`), an Argo CD **Sync** hook Job at wave **6** upserts matching hub top-level `s3StoreProfiles` (primary + secondary only) into `ramen-hub-operator-config` (defaults: hub **vp-s4-storage** credentials and Route) **before** DRClusters (wave 7) and DRPolicy validation (wave 8). **opp-policy** still injects `caCertificates` afterward. If the ConfigMap YAML actually changed, the Job deletes hub operator pods (`app=ramen-hub` in `drCluster.s3StoreProfiles.ramen.namespace`) so the operator reloads config; OLM reverts `rollout restart`, so the Job does not use it. Unchanged ConfigMaps skip the bounce.

### Optional hub Ramen `drClusterOperator` patch

When `ramen.updateRamenConfig` is **true** (default **false**), a separate Sync hook Job at wave **6** patches `drClusterOperator` fields in the hub Ramen ConfigMap (`drCluster.s3StoreProfiles.ramen.configMapName`, default `ramen-hub-operator-config`). The Job and its RBAC are omitted unless this gate is enabled. Like the s3 profiles Job, it restarts hub operator pods only when the patched ConfigMap differs from what was already on the hub.

Values under `ramen.drClusterOperator` parameterize each `yq` edit applied to `ramen_manager_config.yaml`:

| Value                        | Patches                                        |
| ---------------------------- | ---------------------------------------------- |
| `catalogSourceName`          | `drClusterOperator.catalogSourceName`          |
| `catalogSourceNamespaceName` | `drClusterOperator.catalogSourceNamespaceName` |
| `packageName`                | `drClusterOperator.packageName`                |
| `channelName`                | `drClusterOperator.channelName`                |
| `namespaceName`              | `drClusterOperator.namespaceName`              |

Set any field to `false` or `""` to skip that edit and leave the existing hub value unchanged. Job timing and Ramen ConfigMap location reuse `drCluster.s3StoreProfiles.job` and `drCluster.s3StoreProfiles.ramen`.

PostSync settlement: `drpc-health-check` (wave **12**, only when `ramen.resourcesEnabled`) waits for DRPC health.
When `argocd.disableAutomatedSync` is true (default), `argocd-sync-disable` (wave **13**) then removes Application automated sync so the regional-dr app stops reconciling after things settle — including `drpartner-s4` (`resourcesEnabled: false`) and `drpartner-minimal` (both `resourcesEnabled` and `infrastructureEnabled` false).
The Job looks up the Application CR in `global.pattern`-`clusterGroup.name` (not Argo `$ARGOCD_APP_NAMESPACE`, which is the **destination** namespace `regional-dr`) and patches the parent hub Application in `global.vpArgoNamespace` with `ignoreDifferences` on `Application/regional-dr` `/spec/syncPolicy/automated` so hub selfHeal cannot re-enable autosync from Git.
Set `argocd.disableAutomatedSync: false` to leave autosync on.

## Notable changes

v0.1.4 - ConfigMap editor Jobs (`ramen-s3-profiles`, `update-ramen-config`) restart hub Ramen operator pods only when `ramen_manager_config.yaml` actually changed (delete `app=ramen-hub` pods; do not `rollout restart`)
v0.1.3 - Add optional `ramen.updateRamenConfig` gate (default false) with Sync hook Job and RBAC to patch hub Ramen `drClusterOperator` settings via `ramen.drClusterOperator`; set individual fields to `false` or `""` to skip that `yq` edit
v0.1.2 - Parameterize DRPC placement to use values specified.
v0.1.1 - Fix argocd-sync-disable / drpc-health Application CR namespace: use `pattern`-`clusterGroup.name` (not spoke `main.clusterGroupName`, and not `$ARGOCD_APP_NAMESPACE` / `global.namespace` which is destination `regional-dr`); add hub Application ignoreDifferences for regional-dr syncPolicy.automated so disable sticks under parent selfHeal; fail the Job when the Application is missing instead of soft-skipping; gate sync-disable with `argocd.disableAutomatedSync` (default true)
v0.1.0 - Replace `odf.postInstallFixesEnabled` / `odf.drCluster` with `drCluster.create` and default S3 profile names (`s3profile-` plus cluster name); add `ramen.infrastructureEnabled` for DRPolicy/validation/chart DRClusters when `resourcesEnabled` is false; upsert hub Ramen `s3StoreProfiles` when chart-owned DRClusters are created (values-driven, hub S4 defaults; opp-policy still owns `caCertificates`); Sync-hook (not PostSync) so profiles exist before DRPolicy validation; split DRPC health check from Argo CD sync-disable (sync-disable always runs after settlement)
v0.0.4 - Add `ramen.resourcesEnabled` and `edgeGitopsVms.enabled` gates for partner CSI foundation installs
v0.0.3 - Remove all ODF templates (moved to odf-dr-chart)
v0.0.2 - Update edge-gitops-vms version to 0.5.2 to support setting default virt class and direct PVC volumes
v0.0.1 - Initial release

<!-- prettier-ignore-start -->
## Values

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| ansible.configMapArgoSyncOptions | string | `"Prune=false,ServerSideApply=true"` |  |
| ansible.containerImage | string | `"quay.io/validatedpatterns/utility-container:latest"` |  |
| ansible.verbosity | int | `0` |  |
| argocd.disableAutomatedSync | bool | `true` | When true, PostSync Job (wave 13) removes regional-dr Application automated sync and adds hub ignoreDifferences so parent selfHeal cannot re-enable it. Set false to leave autosync on after install. |
| boutique.chartName | string | `"boutique"` |  |
| boutique.chartVersion | string | `"0.0.9"` |  |
| boutique.deploy | bool | `false` |  |
| boutique.helmRepoAlias | string | `"validatedpatterns"` |  |
| boutique.helmRepoUrl | string | `"https://charts.validatedpatterns.io"` |  |
| boutique.namespace | string | `"boutique"` |  |
| byoc | bool | `false` |  |
| clusterCaMgt.createNamespace | bool | `false` | Create clusterCaMgt.namespace when installing the chart. |
| clusterCaMgt.namespace | string | `"cluster-ca-mgt"` | Namespace for ODF CA prerequisites and Ramen trusted-CA workloads. |
| clusterDeployments.awsSecretKey | string | `"secret/hub/aws"` |  |
| clusterDeployments.pullSecretKey | string | `"secret/hub/openshiftPullSecret"` |  |
| clusterDeployments.secretRefreshInterval | string | `"90s"` |  |
| drCluster.create | bool | `false` | When true, render hub DRCluster CRs. When false, expect external automation (e.g. ODF MirrorPeer) unless ramen.infrastructureEnabled is true. |
| drCluster.primaryS3ProfileName | string | `""` | S3 profile name for the primary DRCluster. Empty defaults to `s3profile-` plus the primary cluster name. Must match a profile in hub Ramen config (ramen-hub-operator-config). |
| drCluster.s3StoreProfiles.credentialsSource.name | string | `"s4-credentials"` | Source Secret with AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY. |
| drCluster.s3StoreProfiles.credentialsSource.namespace | string | `"vp-s4-storage"` | Namespace of credentialsSource. |
| drCluster.s3StoreProfiles.endpointSource.routeName | string | `""` | Route name for S3 API. Empty picks first Route with targetPort s3-api in routeNamespace. |
| drCluster.s3StoreProfiles.endpointSource.routeNamespace | string | `"vp-s4-storage"` | Namespace to discover the S3 Route from. |
| drCluster.s3StoreProfiles.ensureBuckets | bool | `true` | When true, create missing buckets named for each profile. |
| drCluster.s3StoreProfiles.job.activeDeadlineSeconds | int | `7200` | Job activeDeadlineSeconds. |
| drCluster.s3StoreProfiles.job.argoCDSyncWave | string | `"6"` | Argo CD Sync-hook wave (before DRClusters at 7 / DRPolicy validation at 8). |
| drCluster.s3StoreProfiles.job.backoffLimit | int | `10` | Job backoffLimit. |
| drCluster.s3StoreProfiles.job.pollInterval | int | `15` | Poll interval while waiting. |
| drCluster.s3StoreProfiles.job.waitSeconds | int | `3600` | Seconds to wait for Ramen ConfigMap and credentials. |
| drCluster.s3StoreProfiles.primary.s3Bucket | string | `""` | Bucket for the primary profile. Empty defaults to the primary profile name. |
| drCluster.s3StoreProfiles.ramen.configKey | string | `"ramen_manager_config.yaml"` | Key holding RamenConfig YAML. |
| drCluster.s3StoreProfiles.ramen.configMapName | string | `"ramen-hub-operator-config"` | Hub Ramen ConfigMap name. |
| drCluster.s3StoreProfiles.ramen.namespace | string | `"openshift-operators"` | Namespace of the hub Ramen operator ConfigMap and operator pods. |
| drCluster.s3StoreProfiles.s3CompatibleEndpoint | string | `""` | S3 endpoint URL. Empty discovers from endpointSource Route. |
| drCluster.s3StoreProfiles.s3Region | string | `"us-east-1"` | S3 region (required by Ramen AWS SDK). |
| drCluster.s3StoreProfiles.s3SecretRef.name | string | `"ramen-s3-credentials"` | Secret Ramen profiles reference (AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY). |
| drCluster.s3StoreProfiles.s3SecretRef.namespace | string | `"openshift-operators"` | Namespace for s3SecretRef (copied from credentialsSource when different). |
| drCluster.s3StoreProfiles.secondary.s3Bucket | string | `""` | Bucket for the secondary profile. Empty defaults to the secondary profile name. |
| drCluster.secondaryS3ProfileName | string | `""` | S3 profile name for the secondary DRCluster. Empty defaults to `s3profile-` plus the secondary cluster name. |
| drpc.drPolicyRef.name | string | `"2m-vm"` |  |
| drpc.healthCheck.deleteWaitDelay | int | `5` |  |
| drpc.healthCheck.deleteWaitRetries | int | `24` |  |
| drpc.healthCheck.maxAttempts | int | `30` |  |
| drpc.healthCheck.retryDelaySeconds | int | `30` |  |
| drpc.kubeObjectProtection.captureInterval | string | `"2m0s"` |  |
| drpc.kubeObjectProtection.kubeObjectSelector | object | `{}` |  |
| drpc.name | string | `"gitops-vm-protection"` |  |
| drpc.namespace | string | `"openshift-dr-ops"` |  |
| drpc.placementRef.name | string | `"gitops-vm-protection-placement-1"` |  |
| drpc.placementRef.namespace | string | `"openshift-dr-ops"` |  |
| drpc.preferredCluster | string | `"ocp-primary"` |  |
| drpc.protectedNamespaces[0] | string | `"gitops-vms"` |  |
| drpc.pvcSelector | object | `{}` |  |
| drpc.vmStorageClassName | string | `"ocs-storagecluster-ceph-rbd-virtualization"` | Block PVC storage class for KubeVirt VMs. drcluster-validation (sync-wave 8) blocks DRPC until DRPolicy status is Validated=True and status.async.peerClasses include replicationID. |
| edgeGitopsVms.chartVersion | string | `"0.5.2"` |  |
| edgeGitopsVms.enabled | bool | `true` | When false, skip the edge-gitops-vms deploy Job and its RBAC/ConfigMap. |
| global.clusterDomain | string | `"cluster.example.com"` |  |
| global.clusterPlatform | string | `"AWS"` |  |
| global.pattern | string | `"ramendr-starter-kit-hub"` |  |
| global.vpArgoNamespace | string | `"vp-gitops"` |  |
| helmUnittest.rdrMerge.enabled | bool | `false` |  |
| helmUnittest.rdrMerge.mergeInstallConfig.base | object | `{}` |  |
| helmUnittest.rdrMerge.mergeInstallConfig.over | object | `{}` |  |
| helmUnittest.s3Profiles.enabled | bool | `false` | Enable rdr-s3-profiles-fixture for helper unit tests. |
| main.clusterGroupName | string | `"resilient"` |  |
| odfRamenTrustedCa.pollInterval | int | `15` |  |
| odfRamenTrustedCa.ramenS3WaitSeconds | int | `3600` |  |
| odfRamenTrustedCa.trustedCaWaitSeconds | int | `3600` |  |
| ramen.drClusterOperator | object | `{"catalogSourceName":"rhdr-catalog","catalogSourceNamespaceName":"openshift-marketplace","channelName":"stable-4.22","namespaceName":"openshift-dr-system","packageName":"rhdr-cluster-operator"}` | drClusterOperator fields written into ramen_manager_config.yaml when updateRamenConfig is true. Set a field to false or "" to leave that key unchanged in the hub ConfigMap. |
| ramen.drClusterOperator.catalogSourceName | string | `"rhdr-catalog"` | OLM catalog source for the DR cluster operator. |
| ramen.drClusterOperator.catalogSourceNamespaceName | string | `"openshift-marketplace"` | Namespace of the OLM catalog source. |
| ramen.drClusterOperator.channelName | string | `"stable-4.22"` | Operator subscription channel. |
| ramen.drClusterOperator.namespaceName | string | `"openshift-dr-system"` | Target namespace for the DR cluster operator. |
| ramen.drClusterOperator.packageName | string | `"rhdr-cluster-operator"` | Operator package name in the catalog. |
| ramen.infrastructureEnabled | bool | `false` | When true (or when resourcesEnabled is true), render DRPolicy, DRCluster validation, and chart-owned DRClusters (see also drCluster.create). |
| ramen.resourcesEnabled | bool | `true` | When false, skip DRPC, Placement, and DRPC health job. DRPolicy/validation/DRClusters still render if infrastructureEnabled is true. |
| ramen.updateRamenConfig | bool | `false` | When true, run the update-ramen-config Job and RBAC to patch hub Ramen ConfigMap (restarts hub operator only if the ConfigMap changed). |
| redis.external.address | string | `"rhel9-redis-001.gitops-vms.svc.cluster.local"` |  |
| redis.external.enabled | bool | `false` |  |
| regionalDR[0].clusters.primary.clusterGroup | string | `"resilient"` |  |
| regionalDR[0].clusters.primary.install_config.apiVersion | string | `"v1"` |  |
| regionalDR[0].clusters.primary.install_config.baseDomain | string | `"{{ join \".\" (slice (splitList \".\" $.Values.global.clusterDomain) 1) }}"` |  |
| regionalDR[0].clusters.primary.install_config.compute[0].name | string | `"worker"` |  |
| regionalDR[0].clusters.primary.install_config.compute[0].platform.aws.type | string | `"m5.metal"` |  |
| regionalDR[0].clusters.primary.install_config.compute[0].replicas | int | `3` |  |
| regionalDR[0].clusters.primary.install_config.controlPlane.name | string | `"master"` |  |
| regionalDR[0].clusters.primary.install_config.controlPlane.platform.aws.type | string | `"m5.4xlarge"` |  |
| regionalDR[0].clusters.primary.install_config.controlPlane.replicas | int | `3` |  |
| regionalDR[0].clusters.primary.install_config.metadata.name | string | `"ocp-primary"` |  |
| regionalDR[0].clusters.primary.install_config.networking.clusterNetwork[0].cidr | string | `"10.132.0.0/14"` |  |
| regionalDR[0].clusters.primary.install_config.networking.clusterNetwork[0].hostPrefix | int | `23` |  |
| regionalDR[0].clusters.primary.install_config.networking.machineNetwork[0].cidr | string | `"10.1.0.0/16"` |  |
| regionalDR[0].clusters.primary.install_config.networking.networkType | string | `"OVNKubernetes"` |  |
| regionalDR[0].clusters.primary.install_config.networking.serviceNetwork[0] | string | `"172.20.0.0/16"` |  |
| regionalDR[0].clusters.primary.install_config.platform.aws.region | string | `"us-west-1"` |  |
| regionalDR[0].clusters.primary.install_config.platform.aws.userTags.project | string | `"ValidatedPatterns"` |  |
| regionalDR[0].clusters.primary.install_config.publish | string | `"External"` |  |
| regionalDR[0].clusters.primary.install_config.pullSecret | string | `""` |  |
| regionalDR[0].clusters.primary.install_config.sshKey | string | `""` |  |
| regionalDR[0].clusters.primary.name | string | `"ocp-primary"` |  |
| regionalDR[0].clusters.primary.version | string | `"4.18.7"` |  |
| regionalDR[0].clusters.secondary.clusterGroup | string | `"resilient"` |  |
| regionalDR[0].clusters.secondary.install_config.apiVersion | string | `"v1"` |  |
| regionalDR[0].clusters.secondary.install_config.baseDomain | string | `"{{ join \".\" (slice (splitList \".\" $.Values.global.clusterDomain) 1) }}"` |  |
| regionalDR[0].clusters.secondary.install_config.compute[0].name | string | `"worker"` |  |
| regionalDR[0].clusters.secondary.install_config.compute[0].platform.aws.type | string | `"m5.metal"` |  |
| regionalDR[0].clusters.secondary.install_config.compute[0].replicas | int | `3` |  |
| regionalDR[0].clusters.secondary.install_config.controlPlane.name | string | `"master"` |  |
| regionalDR[0].clusters.secondary.install_config.controlPlane.platform.aws.type | string | `"m5.4xlarge"` |  |
| regionalDR[0].clusters.secondary.install_config.controlPlane.replicas | int | `3` |  |
| regionalDR[0].clusters.secondary.install_config.metadata.name | string | `"ocp-secondary"` |  |
| regionalDR[0].clusters.secondary.install_config.networking.clusterNetwork[0].cidr | string | `"10.136.0.0/14"` |  |
| regionalDR[0].clusters.secondary.install_config.networking.clusterNetwork[0].hostPrefix | int | `23` |  |
| regionalDR[0].clusters.secondary.install_config.networking.machineNetwork[0].cidr | string | `"10.2.0.0/16"` |  |
| regionalDR[0].clusters.secondary.install_config.networking.networkType | string | `"OVNKubernetes"` |  |
| regionalDR[0].clusters.secondary.install_config.networking.serviceNetwork[0] | string | `"172.21.0.0/16"` |  |
| regionalDR[0].clusters.secondary.install_config.platform.aws.region | string | `"us-east-1"` |  |
| regionalDR[0].clusters.secondary.install_config.platform.aws.userTags.project | string | `"ValidatedPatterns"` |  |
| regionalDR[0].clusters.secondary.install_config.publish | string | `"External"` |  |
| regionalDR[0].clusters.secondary.install_config.pullSecret | string | `""` |  |
| regionalDR[0].clusters.secondary.install_config.sshKey | string | `""` |  |
| regionalDR[0].clusters.secondary.name | string | `"ocp-secondary"` |  |
| regionalDR[0].clusters.secondary.version | string | `"4.18.7"` |  |
| regionalDR[0].drpolicies[0].interval | string | `"2m"` |  |
| regionalDR[0].drpolicies[0].vmSupport | bool | `true` |  |
| regionalDR[0].drpolicies[1].interval | string | `"2m"` |  |
| regionalDR[0].globalnetEnabled | bool | `false` |  |
| regionalDR[0].name | string | `"resilient"` |  |
| secretStore.kind | string | `"ClusterSecretStore"` |  |
| secretStore.name | string | `"vault-backend"` |  |
| submariner.NATTEnable | bool | `true` |  |
| submariner.cableDriver | string | `"vxlan"` |  |
| submariner.instanceType | string | `"m5.xlarge"` |  |
| submariner.ipsecNatPort | int | `4500` |  |
| submariner.sgTagJobEnabled | bool | `false` |  |

----------------------------------------------
Autogenerated from chart metadata using [helm-docs v1.14.2](https://github.com/norwoodj/helm-docs/releases/v1.14.2)
<!-- prettier-ignore-end -->
