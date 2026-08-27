#!/usr/bin/env bash
# Upsert hub Ramen s3StoreProfiles for chart-owned DRClusters (non-ODF / partner path).
# Does not set caCertificates — opp-policy s3CaInjector owns that.
# Requires: oc, yq (mikefarah v4); aws CLI when ENSURE_BUCKETS=true.
set -euo pipefail

RAMEN_NAMESPACE="${RAMEN_NAMESPACE:?RAMEN_NAMESPACE is required}"
RAMEN_CONFIGMAP="${RAMEN_CONFIGMAP:?RAMEN_CONFIGMAP is required}"
RAMEN_CONFIG_KEY="${RAMEN_CONFIG_KEY:-ramen_manager_config.yaml}"
PRIMARY_PROFILE_NAME="${PRIMARY_PROFILE_NAME:?PRIMARY_PROFILE_NAME is required}"
SECONDARY_PROFILE_NAME="${SECONDARY_PROFILE_NAME:?SECONDARY_PROFILE_NAME is required}"
PRIMARY_BUCKET="${PRIMARY_BUCKET:-}"
SECONDARY_BUCKET="${SECONDARY_BUCKET:-}"
S3_ENDPOINT="${S3_ENDPOINT:-}"
S3_REGION="${S3_REGION:-us-east-1}"
ENSURE_BUCKETS="${ENSURE_BUCKETS:-true}"
S3_SECRET_NAME="${S3_SECRET_NAME:?S3_SECRET_NAME is required}"
S3_SECRET_NAMESPACE="${S3_SECRET_NAMESPACE:?S3_SECRET_NAMESPACE is required}"
CREDENTIALS_SOURCE_NAME="${CREDENTIALS_SOURCE_NAME:?CREDENTIALS_SOURCE_NAME is required}"
CREDENTIALS_SOURCE_NAMESPACE="${CREDENTIALS_SOURCE_NAMESPACE:?CREDENTIALS_SOURCE_NAMESPACE is required}"
ENDPOINT_ROUTE_NAME="${ENDPOINT_ROUTE_NAME:-}"
ENDPOINT_ROUTE_NAMESPACE="${ENDPOINT_ROUTE_NAMESPACE:-vp-s4-storage}"
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

PRIMARY_BUCKET="${PRIMARY_BUCKET:-$PRIMARY_PROFILE_NAME}"
SECONDARY_BUCKET="${SECONDARY_BUCKET:-$SECONDARY_PROFILE_NAME}"

# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/restart-ramen-hub-operator.sh"

wait_for_secret() {
	local ns="$1"
	local name="$2"
	local deadline=$((SECONDS + WAIT_SECONDS))
	log "Waiting for Secret ${ns}/${name} (max ${WAIT_SECONDS}s)..."
	while ((SECONDS < deadline)); do
		if oc get secret "$name" -n "$ns" &>/dev/null; then
			local ak
			ak=$(oc get secret "$name" -n "$ns" -o jsonpath='{.data.AWS_ACCESS_KEY_ID}' 2>/dev/null || true)
			if [[ -n "$ak" ]]; then
				log "  Secret ${ns}/${name} ready"
				return 0
			fi
			log "  ... Secret present but AWS_ACCESS_KEY_ID missing, retry in ${POLL_INTERVAL}s"
		else
			log "  ... Secret missing, retry in ${POLL_INTERVAL}s"
		fi
		sleep "$POLL_INTERVAL"
	done
	die "Secret ${ns}/${name} not ready in time"
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

ensure_ramen_secret() {
	wait_for_secret "$CREDENTIALS_SOURCE_NAMESPACE" "$CREDENTIALS_SOURCE_NAME"
	if [[ "$CREDENTIALS_SOURCE_NAMESPACE" == "$S3_SECRET_NAMESPACE" && "$CREDENTIALS_SOURCE_NAME" == "$S3_SECRET_NAME" ]]; then
		log "Ramen Secret is credentials source; no copy needed"
		return 0
	fi
	log "Syncing ${CREDENTIALS_SOURCE_NAMESPACE}/${CREDENTIALS_SOURCE_NAME} -> ${S3_SECRET_NAMESPACE}/${S3_SECRET_NAME}"
	export S3_SECRET_NAME S3_SECRET_NAMESPACE
	oc get secret "$CREDENTIALS_SOURCE_NAME" -n "$CREDENTIALS_SOURCE_NAMESPACE" -o json >"$WORK_DIR/src-secret.json"
	yq eval '
		del(.metadata.resourceVersion, .metadata.uid, .metadata.creationTimestamp,
		    .metadata.ownerReferences, .metadata.managedFields, .metadata.annotations,
		    .metadata.generation) |
		.metadata.name = strenv(S3_SECRET_NAME) |
		.metadata.namespace = strenv(S3_SECRET_NAMESPACE) |
		.metadata.labels = ((.metadata.labels // {}) * {"app.kubernetes.io/name": "ramen-s3-profiles"})
	' "$WORK_DIR/src-secret.json" >"$WORK_DIR/dst-secret.json"
	oc apply -f "$WORK_DIR/dst-secret.json"
}

resolve_endpoint() {
	if [[ -n "$S3_ENDPOINT" ]]; then
		log "Using configured S3_ENDPOINT=${S3_ENDPOINT}"
		return 0
	fi
	local deadline=$((SECONDS + WAIT_SECONDS))
	log "Discovering S3 endpoint from Routes in ${ENDPOINT_ROUTE_NAMESPACE} (max ${WAIT_SECONDS}s)..."
	while ((SECONDS < deadline)); do
		local host=""
		if [[ -n "$ENDPOINT_ROUTE_NAME" ]]; then
			host=$(oc get route "$ENDPOINT_ROUTE_NAME" -n "$ENDPOINT_ROUTE_NAMESPACE" -o jsonpath='{.spec.host}' 2>/dev/null || true)
		else
			# Prefer Route targeting s3-api port (vp-s4-storage *-api Route).
			host=$(oc get route -n "$ENDPOINT_ROUTE_NAMESPACE" -o json 2>/dev/null |
				yq eval -r '
					.items[]
					| select(.spec.port.targetPort == "s3-api" or .spec.port.targetPort == 8080)
					| .spec.host
				' - 2>/dev/null | head -n1 | tr -d ' \n\r' || true)
			if [[ -z "$host" ]]; then
				host=$(oc get route -n "$ENDPOINT_ROUTE_NAMESPACE" -o jsonpath='{.items[0].spec.host}' 2>/dev/null || true)
			fi
		fi
		if [[ -n "$host" ]]; then
			S3_ENDPOINT="https://${host}"
			log "  Discovered S3_ENDPOINT=${S3_ENDPOINT}"
			return 0
		fi
		log "  ... Route host not ready, retry in ${POLL_INTERVAL}s"
		sleep "$POLL_INTERVAL"
	done
	die "Could not resolve S3 endpoint (set drCluster.s3StoreProfiles.s3CompatibleEndpoint or fix endpointSource)"
}

export_aws_creds() {
	local ak sk
	ak=$(oc get secret "$S3_SECRET_NAME" -n "$S3_SECRET_NAMESPACE" -o jsonpath='{.data.AWS_ACCESS_KEY_ID}' | base64 -d)
	sk=$(oc get secret "$S3_SECRET_NAME" -n "$S3_SECRET_NAMESPACE" -o jsonpath='{.data.AWS_SECRET_ACCESS_KEY}' | base64 -d)
	[[ -n "$ak" && -n "$sk" ]] || die "Secret ${S3_SECRET_NAMESPACE}/${S3_SECRET_NAME} missing AWS keys"
	export AWS_ACCESS_KEY_ID="$ak"
	export AWS_SECRET_ACCESS_KEY="$sk"
	export AWS_DEFAULT_REGION="$S3_REGION"
	export AWS_EC2_METADATA_DISABLED=true
}

ensure_bucket() {
	local bucket="$1"
	command -v aws >/dev/null 2>&1 || die "aws CLI not found (required when ENSURE_BUCKETS=true)"
	log "Ensuring bucket ${bucket} at ${S3_ENDPOINT}"
	if aws --endpoint-url "$S3_ENDPOINT" s3api head-bucket --bucket "$bucket" 2>/dev/null; then
		log "  Bucket ${bucket} exists"
		return 0
	fi
	if aws --endpoint-url "$S3_ENDPOINT" s3api create-bucket --bucket "$bucket" 2>/dev/null ||
		aws --endpoint-url "$S3_ENDPOINT" s3 mb "s3://${bucket}" 2>/dev/null; then
		log "  Created bucket ${bucket}"
		return 0
	fi
	die "Failed to create bucket ${bucket}"
}

# Upsert one profile into top-level s3StoreProfiles (what DRCluster/DRPolicy use).
# Preserves caCertificates and other unknown fields when updating.
# Does not write kubeObjectProtection.s3StoreProfiles — not part of current RamenConfig.
upsert_one() {
	local f="$1"
	local name="$2"
	local bucket="$3"

	export PROFILE_NAME="$name"
	export PROFILE_BUCKET="$bucket"
	export PROFILE_ENDPOINT="$S3_ENDPOINT"
	export PROFILE_REGION="$S3_REGION"
	export PROFILE_SECRET_NAME="$S3_SECRET_NAME"
	export PROFILE_SECRET_NS="$S3_SECRET_NAMESPACE"

	yq eval -i '.s3StoreProfiles = (.s3StoreProfiles // [])' "$f"

	local idx=""
	idx=$(yq eval '
		(.s3StoreProfiles // [])
		| to_entries
		| map(select(.value.s3ProfileName == strenv(PROFILE_NAME)))
		| .[0].key // ""
	' "$f")

	if [[ -n "$idx" && "$idx" != "null" ]]; then
		log "  Updating profile ${name}[${idx}]"
		yq eval -i "
			.s3StoreProfiles[${idx}].s3Bucket = strenv(PROFILE_BUCKET) |
			.s3StoreProfiles[${idx}].s3CompatibleEndpoint = strenv(PROFILE_ENDPOINT) |
			.s3StoreProfiles[${idx}].s3Region = strenv(PROFILE_REGION) |
			.s3StoreProfiles[${idx}].s3SecretRef.name = strenv(PROFILE_SECRET_NAME) |
			.s3StoreProfiles[${idx}].s3SecretRef.namespace = strenv(PROFILE_SECRET_NS)
		" "$f"
	else
		log "  Appending profile ${name}"
		local new_profile
		new_profile=$(yq eval -n '{
			"s3ProfileName": strenv(PROFILE_NAME),
			"s3Bucket": strenv(PROFILE_BUCKET),
			"s3CompatibleEndpoint": strenv(PROFILE_ENDPOINT),
			"s3Region": strenv(PROFILE_REGION),
			"s3SecretRef": {
				"name": strenv(PROFILE_SECRET_NAME),
				"namespace": strenv(PROFILE_SECRET_NS)
			}
		}')
		printf '%s\n' "$new_profile" >"$WORK_DIR/new-profile.yaml"
		yq eval -i ".s3StoreProfiles += [load(\"${WORK_DIR}/new-profile.yaml\")]" "$f"
	fi
}

apply_profiles() {
	local f="$WORK_DIR/ramen_manager_config.yaml"
	local jp
	jp=$(jsonpath_for_key "$RAMEN_CONFIG_KEY")
	oc get configmap "$RAMEN_CONFIGMAP" -n "$RAMEN_NAMESPACE" -o "jsonpath=${jp}" >"$f" || true
	if [[ ! -s "$f" ]]; then
		log "Empty ${RAMEN_CONFIG_KEY}; initializing minimal RamenConfig"
		cat >"$f" <<EOF
apiVersion: ramendr.openshift.io/v1alpha1
kind: RamenConfig
ramenControllerType: dr-hub
s3StoreProfiles: []
EOF
	fi

	cp "$f" "$WORK_DIR/before.yaml"
	upsert_one "$f" "$PRIMARY_PROFILE_NAME" "$PRIMARY_BUCKET"
	upsert_one "$f" "$SECONDARY_PROFILE_NAME" "$SECONDARY_BUCKET"
	apply_ramen_config_if_changed "$WORK_DIR/before.yaml" "$f"

	oc get configmap "$RAMEN_CONFIGMAP" -n "$RAMEN_NAMESPACE" -o "jsonpath=${jp}" >"$WORK_DIR/verify.yaml"
	for n in "$PRIMARY_PROFILE_NAME" "$SECONDARY_PROFILE_NAME"; do
		export VERIFY_NAME="$n"
		if ! yq eval -r '(.s3StoreProfiles // [])[] | select(.s3ProfileName == strenv(VERIFY_NAME)) | .s3ProfileName' "$WORK_DIR/verify.yaml" | grep -qx "$n"; then
			die "Verification failed: profile ${n} missing from s3StoreProfiles"
		fi
	done
	log "Upserted s3StoreProfiles ${PRIMARY_PROFILE_NAME} and ${SECONDARY_PROFILE_NAME} in ${RAMEN_NAMESPACE}/${RAMEN_CONFIGMAP}"
}

main() {
	log "=== Ramen s3StoreProfiles upsert ==="
	wait_for_ramen_cm
	ensure_ramen_secret
	resolve_endpoint
	if [[ "${ENSURE_BUCKETS}" == "true" ]]; then
		export_aws_creds
		ensure_bucket "$PRIMARY_BUCKET"
		ensure_bucket "$SECONDARY_BUCKET"
	fi
	apply_profiles
	log "=== Done ==="
}

main "$@"
