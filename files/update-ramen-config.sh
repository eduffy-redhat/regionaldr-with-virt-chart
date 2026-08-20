#!/usr/bin/env bash
# Upsert hub Ramen s3StoreProfiles for chart-owned DRClusters (non-ODF / partner path).
# Does not set caCertificates — opp-policy s3CaInjector owns that.
# Requires: oc, yq (mikefarah v4); aws CLI when ENSURE_BUCKETS=true.
set -euo pipefail

RAMEN_NAMESPACE="${RAMEN_NAMESPACE:?RAMEN_NAMESPACE is required}"
RAMEN_CONFIGMAP="${RAMEN_CONFIGMAP:?RAMEN_CONFIGMAP is required}"
RAMEN_CONFIG_KEY="${RAMEN_CONFIG_KEY:-ramen_manager_config.yaml}"
WAIT_SECONDS="${WAIT_SECONDS:-3600}"
POLL_INTERVAL="${POLL_INTERVAL:-15}"
WORK_DIR="${WORK_DIR:-/tmp/rdr-s3-profiles}"

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

jsonpath_for_key() {
	local key="$1"
	echo "{.data.$(printf '%s' "$key" | sed 's/\./\\./g')}"
}

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

patch() {
	local f="$1"

	yq eval -i '.drClusterOperator.catalogSourceName="ramen-catalog"' "$f"
	yq eval -i '.drClusterOperator.catalogSourceNamespaceName="openshift-dr-system"' "$f"

}

apply_patches() {
	local f="$WORK_DIR/ramen_manager_config.yaml"
	local jp
	jp=$(jsonpath_for_key "$RAMEN_CONFIG_KEY")
	oc get configmap "$RAMEN_CONFIGMAP" -n "$RAMEN_NAMESPACE" -o "jsonpath=${jp}" >"$f" || true
	if [[ ! -s "$f" ]]; then
		die "Empty ${RAMEN_CONFIG_KEY}; Panic!"
	fi

	patch "$f"

	oc get configmap "$RAMEN_CONFIGMAP" -n "$RAMEN_NAMESPACE" -o yaml >"$WORK_DIR/cm.yaml"
	# load_str embeds the YAML file as a string value for the data key
	yq eval -i ".data.\"${RAMEN_CONFIG_KEY}\" = load_str(\"${f}\")" "$WORK_DIR/cm.yaml"
	oc apply -f "$WORK_DIR/cm.yaml"

	log "Successfully patched ramen config in ${RAMEN_NAMESPACE}/${RAMEN_CONFIGMAP}"
}

main() {
	log "=== Ramen s3StoreProfiles upsert ==="
	wait_for_ramen_cm

	apply_patches
	log "=== Done ==="
}

main "$@"
