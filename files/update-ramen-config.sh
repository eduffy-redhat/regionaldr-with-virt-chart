#!/usr/bin/env bash
# Patch hub Ramen drClusterOperator settings and ramenOpsNamespace in ramen_manager_config.yaml.
# Requires: oc, yq (mikefarah v4).
set -euo pipefail

RAMEN_NAMESPACE="${RAMEN_NAMESPACE:?RAMEN_NAMESPACE is required}"
RAMEN_CONFIGMAP="${RAMEN_CONFIGMAP:?RAMEN_CONFIGMAP is required}"
RAMEN_CONFIG_KEY="${RAMEN_CONFIG_KEY:-ramen_manager_config.yaml}"
DR_CLUSTER_OPERATOR_CATALOG_SOURCE_NAME="${DR_CLUSTER_OPERATOR_CATALOG_SOURCE_NAME:-}"
DR_CLUSTER_OPERATOR_CATALOG_SOURCE_NAMESPACE="${DR_CLUSTER_OPERATOR_CATALOG_SOURCE_NAMESPACE:-}"
DR_CLUSTER_OPERATOR_PACKAGE_NAME="${DR_CLUSTER_OPERATOR_PACKAGE_NAME:-}"
DR_CLUSTER_OPERATOR_CHANNEL_NAME="${DR_CLUSTER_OPERATOR_CHANNEL_NAME:-}"
DR_CLUSTER_OPERATOR_NAMESPACE="${DR_CLUSTER_OPERATOR_NAMESPACE:-}"
RAMEN_OPS_NAMESPACE="${RAMEN_OPS_NAMESPACE:-}"
WAIT_SECONDS="${WAIT_SECONDS:-3600}"
POLL_INTERVAL="${POLL_INTERVAL:-15}"
WORK_DIR="${WORK_DIR:-/tmp/update-ramen-config}"

die() {
	echo "ERROR: $*" >&2
	exit 1
}

log() {
	echo "$*"
}

command -v oc >/dev/null 2>&1 || die "oc not found"
command -v yq >/dev/null 2>&1 || die "yq not found (need mikefarah/yq v4)"

mkdir -p "$WORK_DIR"

# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/restart-ramen-hub-operator.sh"

wait_for_ramen_cm() {
	local deadline=$((SECONDS + WAIT_SECONDS))
	log "Waiting for ConfigMap ${RAMEN_NAMESPACE}/${RAMEN_CONFIGMAP} (max ${WAIT_SECONDS}s)..."
	while ((SECONDS < deadline)); do
		if oc get configmap "$RAMEN_CONFIGMAP" -n "$RAMEN_NAMESPACE" &>/dev/null; then
			log "  ConfigMap ready"
			return 0
		fi
		log "  ... ConfigMap missing, retry in ${POLL_INTERVAL}s"
		sleep "$POLL_INTERVAL"
	done
	die "ConfigMap ${RAMEN_NAMESPACE}/${RAMEN_CONFIGMAP} not ready in time (is Ramen/MCO installed?)"
}

should_patch_field() {
	local value="$1"
	[[ -n "$value" && "${value,,}" != "false" ]]
}

patch_field() {
	local f="$1"
	local yq_path="$2"
	local value="$3"

	if should_patch_field "$value"; then
		yq eval -i "${yq_path}=\"${value}\"" "$f"
	fi
}

patch() {
	local f="$1"

	patch_field "$f" ".drClusterOperator.catalogSourceName" "$DR_CLUSTER_OPERATOR_CATALOG_SOURCE_NAME"
	patch_field "$f" ".drClusterOperator.catalogSourceNamespaceName" "$DR_CLUSTER_OPERATOR_CATALOG_SOURCE_NAMESPACE"
	patch_field "$f" ".drClusterOperator.packageName" "$DR_CLUSTER_OPERATOR_PACKAGE_NAME"
	patch_field "$f" ".drClusterOperator.channelName" "$DR_CLUSTER_OPERATOR_CHANNEL_NAME"
	patch_field "$f" ".drClusterOperator.namespaceName" "$DR_CLUSTER_OPERATOR_NAMESPACE"
	patch_field "$f" ".ramenOpsNamespace" "$RAMEN_OPS_NAMESPACE"
}

apply_patches() {
	local f="$WORK_DIR/ramen_manager_config.yaml"
	local jp
	jp=$(jsonpath_for_key "$RAMEN_CONFIG_KEY")
	oc get configmap "$RAMEN_CONFIGMAP" -n "$RAMEN_NAMESPACE" -o "jsonpath=${jp}" >"$f" || true
	if [[ ! -s "$f" ]]; then
		die "Empty ${RAMEN_CONFIG_KEY}; Panic!"
	fi

	cp "$f" "$WORK_DIR/before.yaml"
	patch "$f"

	local ops_ns operator_ns
	ops_ns=$(yq eval '.ramenOpsNamespace // ""' "$f")
	operator_ns=$(yq eval '.drClusterOperator.namespaceName // ""' "$f")
	if [[ -n "$ops_ns" && -n "$operator_ns" && "$ops_ns" == "$operator_ns" ]]; then
		die "ramenOpsNamespace (${ops_ns}) must differ from drClusterOperator.namespaceName (ACM ManifestWork cannot include two v1.Namespace objects for the same name)"
	fi

	apply_ramen_config_if_changed "$WORK_DIR/before.yaml" "$f"
}

main() {
	log "=== Ramen hub config update ==="
	wait_for_ramen_cm

	apply_patches
	log "=== Done ==="
}

main "$@"
