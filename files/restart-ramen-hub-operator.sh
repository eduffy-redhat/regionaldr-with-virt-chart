#!/usr/bin/env bash
# Shared by ConfigMap editor jobs. Bounce ramen-hub-operator only when the
# Ramen ConfigMap YAML actually changed. OLM reverts Deployment
# rollout-restart annotations, so delete the pods and wait for Ready.
#
# Expects: oc, yq (mikefarah v4), RAMEN_NAMESPACE, RAMEN_CONFIGMAP,
# RAMEN_CONFIG_KEY, WORK_DIR, log(), die().
HUB_OPERATOR_LABEL_SELECTOR="${HUB_OPERATOR_LABEL_SELECTOR:-app=ramen-hub}"
HUB_OPERATOR_READY_TIMEOUT="${HUB_OPERATOR_READY_TIMEOUT:-300}"

jsonpath_for_key() {
	local key="$1"
	echo "{.data.$(printf '%s' "$key" | sed 's/\./\\./g')}"
}

# Canonical JSON (sorted map keys) so style/key-order is not a change.
# sort_keys(..) does not reorder arrays (s3StoreProfiles stay in place).
config_yaml_equal() {
	local a="$1"
	local b="$2"
	local ha hb
	ha=$(yq eval -o=json -I=0 'sort_keys(..)' "$a")
	hb=$(yq eval -o=json -I=0 'sort_keys(..)' "$b")
	[[ "$ha" == "$hb" ]]
}

restart_hub_operator() {
	local ns="${RAMEN_NAMESPACE:?RAMEN_NAMESPACE is required}"
	local sel="$HUB_OPERATOR_LABEL_SELECTOR"
	local timeout="$HUB_OPERATOR_READY_TIMEOUT"
	local deadline

	log "Restarting hub Ramen operator pods in ${ns} (selector ${sel})"
	if ! oc get pods -n "$ns" -l "$sel" --no-headers 2>/dev/null | grep -q .; then
		die "No hub operator pods found in ${ns} with selector ${sel}"
	fi

	oc delete pods -n "$ns" -l "$sel" --wait=true --timeout="${timeout}s"

	deadline=$((SECONDS + timeout))
	while ((SECONDS < deadline)); do
		if oc wait --for=condition=Ready pod -n "$ns" -l "$sel" --timeout=15s 2>/dev/null; then
			log "Hub operator is Ready"
			return 0
		fi
		sleep 2
	done
	die "Hub operator did not become Ready in ${timeout}s"
}

# Apply patched ramen_manager_config.yaml if it differs from before_file.
# Bounce the hub operator only when apply happens.
apply_ramen_config_if_changed() {
	local before_file="$1"
	local after_file="$2"
	local jp

	jp=$(jsonpath_for_key "$RAMEN_CONFIG_KEY")

	if config_yaml_equal "$before_file" "$after_file"; then
		log "Ramen ConfigMap ${RAMEN_NAMESPACE}/${RAMEN_CONFIGMAP} is already up to date; not restarting hub operator"
		return 0
	fi

	oc get configmap "$RAMEN_CONFIGMAP" -n "$RAMEN_NAMESPACE" -o yaml >"$WORK_DIR/cm.yaml"
	yq eval -i ".data.\"${RAMEN_CONFIG_KEY}\" = load_str(\"${after_file}\")" "$WORK_DIR/cm.yaml"
	oc apply -f "$WORK_DIR/cm.yaml"
	log "Patched ramen config in ${RAMEN_NAMESPACE}/${RAMEN_CONFIGMAP}"

	oc get configmap "$RAMEN_CONFIGMAP" -n "$RAMEN_NAMESPACE" -o "jsonpath=${jp}" >"$WORK_DIR/verify-applied.yaml"
	if ! config_yaml_equal "$after_file" "$WORK_DIR/verify-applied.yaml"; then
		die "ConfigMap apply did not persist expected ramen_manager_config.yaml"
	fi

	restart_hub_operator
}
