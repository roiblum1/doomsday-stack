#!/bin/bash
#
# Chronos GPU Clock Manager - Watch-based (Event-Driven)
# Uses Kubernetes Watch API instead of polling for near-instant response
# Performance: < 100ms response time regardless of cluster size
#
# Watches GPU pods in phases: Running, Pending, ContainerCreating
# (GPU allocation happens before pods reach Running state)
#
# Supported GPU platforms:
#   - Standard NVIDIA GPU (nvidia.com/gpu)
#   - NVIDIA Run:AI (fractional GPUs, job scheduling)
#   - GPU Time-Slicing (multiple pods per GPU)
#

set -euo pipefail

# nvidia-smi lives at /run/nvidia/driver/bin/nvidia-smi (host driver mount) and
# needs libnvidia-ml.so from /run/nvidia/driver/usr/lib64. We can't add that
# dir to LD_LIBRARY_PATH because it also ships an incompatible libc.so.6 that
# breaks the container's own commands (date, mkdir, etc.). LD_PRELOAD loads
# just the one library by full path without polluting the search path.
nvidia-smi() {
    LD_PRELOAD="/run/nvidia/driver/usr/lib64/libnvidia-ml.so.1" \
        /run/nvidia/driver/bin/nvidia-smi "$@"
}

LOCKED_FILE="/tmp/chronos.locked"
NODE_NAME="${NODE_NAME:-$(hostname)}"
DAEMONSET_NAMESPACE="${DAEMONSET_NAMESPACE:-bishbash}"
DAEMONSET_RELEASE="${DAEMONSET_RELEASE:-chronos-poc}"

# In-memory state (file-based for debugging)
STATE_FILE="/tmp/chronos.state"
GPU_COUNT_FILE="/tmp/chronos.gpu.count"

# Run:AI specific configuration
RUNAI_ENABLED="${RUNAI_ENABLED:-false}"

# Pod phases to watch for GPU detection
# Include Pending/ContainerCreating since GPU allocation happens before Running
PHASES_WATCH="${PHASES_WATCH:-Running,Pending,ContainerCreating}"

# Track our own pod name (cached)
OUR_POD_NAME=""

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

# Initialize state
init_state() {
    echo "0" > "${GPU_COUNT_FILE}"
    echo "unknown" > "${STATE_FILE}"
    log "Chronos initialized (Run:AI support: ${RUNAI_ENABLED})"
}

# Get our own pod name (find regardless of phase - may be Pending/ContainerCreating)
get_our_pod_name() {
    # Try Running first, then fall back to any phase
    local pod_name
    pod_name=$(kubectl get pods -n "${DAEMONSET_NAMESPACE}" \
        -l "app=${DAEMONSET_RELEASE}" \
        --field-selector=status.phase=Running \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

    # If not found in Running, try Pending
    if [[ -z "${pod_name}" ]]; then
        pod_name=$(kubectl get pods -n "${DAEMONSET_NAMESPACE}" \
            -l "app=${DAEMONSET_RELEASE}" \
            --field-selector=status.phase=Pending \
            -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    fi

    # If still not found, try ContainerCreating
    if [[ -z "${pod_name}" ]]; then
        pod_name=$(kubectl get pods -n "${DAEMONSET_NAMESPACE}" \
            -l "app=${DAEMONSET_RELEASE}" \
            --field-selector=status.phase=ContainerCreating \
            -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    fi

    echo "${pod_name}"
}

# Check if a specific pod requests GPU resources
# Supports:
#   - Standard nvidia.com/gpu (integer and fractional values)
#   - Run:AI fractional GPUs (0.5, 0.25, 1.0, etc.)
#   - Multiple containers with GPU requests
check_pod_requests_gpu() {
    local namespace="$1"
    local pod_name="$2"

    # Skip kube-system (these don't directly request GPU)
    [[ "${namespace}" == "kube-system" ]] && return 1

    # Skip our own pod (check both namespace and name to avoid false positives
    # if another pod happens to have the same name in a different namespace)
    [[ "${namespace}" == "${DAEMONSET_NAMESPACE}" && "${pod_name}" == "${OUR_POD_NAME}" ]] && return 1

    # Get all GPU resource requests from all containers (main + init)
    # Using jsonpath to get all values as space-separated list
    local all_gpu_requests
    all_gpu_requests=$(kubectl get pod "${pod_name}" -n "${namespace}" \
        -o jsonpath='{.spec.containers[*].resources.requests["nvidia.com/gpu"]}' \
        2>/dev/null || echo "")

    # Also check init containers for GPU requests
    local init_gpu_requests
    init_gpu_requests=$(kubectl get pod "${pod_name}" -n "${namespace}" \
        -o jsonpath='{.spec.initContainers[*].resources.requests["nvidia.com/gpu"]}' \
        2>/dev/null || echo "")

    # Combine all GPU requests
    local combined="${all_gpu_requests} ${init_gpu_requests}"

    # If empty, pod doesn't request GPU
    [[ -z "${combined}" ]] && return 1

    # Parse each GPU request value
    # Supports fractional values: 0.5, 0.25, 1, 2, etc.
    for gpu_val in ${combined}; do
        # Skip empty values
        [[ -z "${gpu_val}" ]] && continue

        # Skip special kubectl output values
        [[ "${gpu_val}" == "<none>" ]] && continue
        [[ "${gpu_val}" == "<nil>" ]] && continue
        [[ "${gpu_val}" == "<undefined>" ]] && continue

        # Validate it's a number (integer or fractional)
        # Accept: 1, 0.5, 0.25, 2, 0.1, etc.
        if [[ "${gpu_val}" =~ ^[0-9]+\.?[0-9]*$ ]] || \
           [[ "${gpu_val}" =~ ^[0-9]*\.?[0-9]+$ ]]; then
            # Check it's greater than 0
            local num_val
            num_val=$(echo "${gpu_val}" | awk '{print ($0 + 0)}')
            if [[ $(echo "${num_val} > 0" | bc -l 2>/dev/null || echo "0") -gt 0 ]] || \
               [[ "${num_val}" -gt 0 ]] 2>/dev/null; then
                # Found a valid GPU request
                log "GPU detected: ${namespace}/${pod_name} requests ${gpu_val} GPU(s)"
                return 0
            fi
        fi
    done

    return 1
}

# Alternative faster check using labels (for Run:AI optimization)
# Run:AI may add specific labels to GPU workloads
# Only used when RUNAI_ENABLED is true
check_pod_has_gpu_label() {
    # Skip if run-ai support is disabled
    [[ "${RUNAI_ENABLED}" != "true" ]] && return 1

    local namespace="$1"
    local pod_name="$2"

    # Check for common GPU-related labels
    local has_label="false"

    # Check for nvidia.com/gpu label (some setups use labels instead of resources)
    local nvidia_label
    nvidia_label=$(kubectl get pod "${pod_name}" -n "${namespace}" \
        -o jsonpath='{.metadata.labels.nvidia\\.com/gpu}' 2>/dev/null || echo "")
    [[ -n "${nvidia_label}" && "${nvidia_label}" != "false" && "${nvidia_label}" != "0" ]] && has_label="true"

    [[ "${has_label}" == "true" ]] && return 0
    return 1
}

# Get count of GPU pods on this node (for validation)
# Works with standard NVIDIA GPU and Run:AI fractional GPUs (regardless of RUNAI_ENABLED)
# Includes Running, Pending, and ContainerCreating pods
get_gpu_pod_count_on_node() {
    # Disable set -e temporarily for this operation
    set +e
    local count=0
    local kubectl_output
    kubectl_output=$(kubectl get pods \
        --all-namespaces \
        --field-selector=spec.nodeName="${NODE_NAME}" \
        -o custom-columns=NAMESPACE:.metadata.namespace,NAME:.metadata.name,PHASE:.status.phase,GPU:.spec.containers[*].resources.requests.nvidia\\.com/gpu \
        --no-headers 2>&1)
    local kubectl_status=$?

    if [[ ${kubectl_status} -eq 0 ]]; then
        # Filter: exclude kube-system, our own pod, and filter by phase (3rd column)
        local filtered_output
        filtered_output=$(echo "${kubectl_output}" | awk \
            '$1 != "kube-system" && \
             ! ($1 == "'"${DAEMONSET_NAMESPACE}"'" && $2 == "'"${OUR_POD_NAME}"'") && \
             ($3 == "Running" || $3 == "Pending" || $3 == "ContainerCreating") { print }' 2>/dev/null || true)

        # Disable set -e for wc -l since it returns 1 when counting 0 lines
        set +e
        count=$(echo "${filtered_output}" | while IFS= read -r line; do
            # Extract GPU column (4th column now due to PHASE)
            local gpu_val
            gpu_val=$(echo "${line}" | awk '{print $NF}')

            # Skip empty, <none>, <nil>
            [[ -z "${gpu_val}" ]] && continue
            [[ "${gpu_val}" == "<none>" ]] && continue
            [[ "${gpu_val}" == "<nil>" ]] && continue
            [[ "${gpu_val}" == "<undefined>" ]] && continue

            # Accept numeric values (including fractional: 0.5, 1, 2, etc.)
            if [[ "${gpu_val}" =~ ^[0-9]+\.?[0-9]*$ ]] || \
               [[ "${gpu_val}" =~ ^[0-9]*\.?[0-9]+$ ]]; then
                echo "1"
            fi
        done | wc -l || true)
        set -e
    fi

    set -e
    echo "${count}"
}

# Update GPU count from events
update_gpu_count() {
    local event_type="$1"  # ADDED, MODIFIED, DELETED
    local namespace="$2"
    local pod_name="$3"

    local current_count
    current_count=$(cat "${GPU_COUNT_FILE}" 2>/dev/null || echo 0)

    case "${event_type}" in
        ADDED|MODIFIED)
            # Check if pod requests GPU (supports standard and Run:AI fractional GPUs)
            if check_pod_requests_gpu "${namespace}" "${pod_name}"; then
                # Pod requests GPU and is on this node
                local is_on_node
                is_on_node=$(kubectl get pod "${pod_name}" -n "${namespace}" \
                    -o jsonpath='{.spec.nodeName}' 2>/dev/null || echo "")

                if [[ "${is_on_node}" == "${NODE_NAME}" ]]; then
                    # Verify it's not already counted
                    local was_tracked
                    was_tracked=$(grep -l "${namespace}/${pod_name}" /tmp/chronos.gpu.pods 2>/dev/null || echo "")

                    if [[ -z "${was_tracked}" ]]; then
                        echo "${namespace}/${pod_name}" >> /tmp/chronos.gpu.pods
                        current_count=$((current_count + 1))
                        echo "${current_count}" > "${GPU_COUNT_FILE}"

                        # Get GPU amount for logging
                        local gpu_amount
                        gpu_amount=$(kubectl get pod "${pod_name}" -n "${namespace}" \
                            -o jsonpath='{.spec.containers[0].resources.requests["nvidia.com/gpu"]}' 2>/dev/null || echo "1")
                        [[ -z "${gpu_amount}" ]] && gpu_amount="1"

                        log "GPU pod added: ${namespace}/${pod_name} (${gpu_amount} GPU, total: ${current_count})"
                    fi
                fi
            fi
            ;;
        DELETED)
            local pod_file="/tmp/chronos.gpu.pods"
            if grep -q "${namespace}/${pod_name}" "${pod_file}" 2>/dev/null; then
                grep -v "${namespace}/${pod_name}" "${pod_file}" > /tmp/chronos.gpu.pods.tmp
                mv /tmp/chronos.gpu.pods.tmp /tmp/chronos.gpu.pods
                current_count=$((current_count - 1))
                [[ ${current_count} -lt 0 ]] && current_count=0
                echo "${current_count}" > "${GPU_COUNT_FILE}"
                log "GPU pod removed: ${namespace}/${pod_name} (total: ${current_count})"
            fi
            ;;
    esac

    echo "${current_count}"
}

# Lock GPU clocks
lock_gpu_clocks() {
    [[ -f "${LOCKED_FILE}" ]] && return 0

    log "Locking GPU clocks..."

    # Disable set -e for nvidia-smi commands to prevent silent exits
    set +e

    # Query max graphics clock - SIGPIPE (exit 141) is OK if we got output
    local max_gfx
    max_gfx=$(nvidia-smi --query-gpu=clocks.max.graphics --format=csv,noheader,nounits 2>/dev/null | head -n1)
    local gfx_status=${PIPESTATUS[0]}

    # Query max memory clock - SIGPIPE (exit 141) is OK if we got output
    local max_mem
    max_mem=$(nvidia-smi --query-gpu=clocks.max.memory --format=csv,noheader,nounits 2>/dev/null | head -n1)
    local mem_status=${PIPESTATUS[0]}

    set -e

    # Check if we got valid output (ignore SIGPIPE exit 141 if we have data)
    if [[ -z "${max_gfx}" ]] || [[ ${gfx_status} -ne 0 && ${gfx_status} -ne 141 ]]; then
        log "ERROR: Failed to query max graphics clock: '${max_gfx}' (exit: ${gfx_status})"
        return 1
    fi

    if [[ -z "${max_mem}" ]] || [[ ${mem_status} -ne 0 && ${mem_status} -ne 141 ]]; then
        log "ERROR: Failed to query max memory clock: '${max_mem}' (exit: ${mem_status})"
        return 1
    fi

    log "Setting clocks: gfx=${max_gfx}, mem=${max_mem}"

    set +e
    nvidia-smi -lgc "${max_gfx}" 2>&1
    local lock_gfx_status=$?
    set -e

    if [[ ${lock_gfx_status} -ne 0 ]]; then
        log "ERROR: Failed to lock graphics clock (exit: ${lock_gfx_status})"
        return 1
    fi

    set +e
    nvidia-smi -lmc "${max_mem}" 2>&1
    local lock_mem_status=$?
    set -e

    if [[ ${lock_mem_status} -ne 0 ]]; then
        log "ERROR: Failed to lock memory clock (exit: ${lock_mem_status})"
        nvidia-smi -rgc 2>/dev/null
        return 1
    fi

    touch "${LOCKED_FILE}"
    echo "gfx=${max_gfx} mem=${max_mem}" > /tmp/chronos.lock
    echo "locked" > "${STATE_FILE}"

    log "GPU clocks locked (gfx:${max_gfx} mem:${max_mem})"
}

# Unlock GPU clocks
unlock_gpu_clocks() {
    [[ ! -f "${LOCKED_FILE}" ]] && return 0

    log "Unlocking GPU clocks..."

    set +e
    nvidia-smi -rgc 2>&1
    local rgc_status=$?
    nvidia-smi -rmc 2>&1
    local rmc_status=$?
    set -e

    if [[ ${rgc_status} -ne 0 ]]; then
        log "WARN: Failed to reset graphics clock (exit: ${rgc_status})"
    fi
    if [[ ${rmc_status} -ne 0 ]]; then
        log "WARN: Failed to reset memory clock (exit: ${rmc_status})"
    fi

    rm -f "${LOCKED_FILE}"
    echo "unlocked" > "${STATE_FILE}"

    log "GPU clocks released"
}

# Wait for NVIDIA driver
wait_for_driver() {
    log "Waiting for NVIDIA driver..."
    local retries=0
    while ! nvidia-smi &>/dev/null; do
        sleep 1
        retries=$((retries + 1))
        [[ ${retries} -gt 120 ]] && log "Timeout, continuing..." && return 0
    done

    # Wait for validation files
    retries=0
    while true; do
        if [[ -f /run/nvidia/validations/driver-ready ]] || \
           [[ -f /run/nvidia/validations/cuda-ready ]] || \
           [[ -f /run/nvidia/validations/plugin-ready ]] || \
           [[ -f /run/nvidia/validations/toolkit-ready ]]; then
            log "Driver ready"
            return 0
        fi
        sleep 1
        retries=$((retries + 1))
        [[ ${retries} -gt 120 ]] && log "Timeout, continuing..." && return 0
    done
}

# Process watch events
process_watch_events() {
    local event_count=0

    while read -r line; do
        [[ -z "${line}" ]] && continue

        # Parse event: TYPE NAME NAMESPACE ...
        local event_type pod_name namespace
        event_type=$(echo "${line}" | awk '{print $1}')
        pod_name=$(echo "${line}" | awk '{print $2}')
        namespace=$(echo "${line}" | awk '{print $3}')

        [[ -z "${event_type}" || -z "${pod_name}" || -z "${namespace}" ]] && continue

        # Update GPU count based on event
        local gpu_count
        gpu_count=$(update_gpu_count "${event_type}" "${namespace}" "${pod_name}")

        # Take action based on GPU count
        if [[ ${gpu_count} -gt 0 ]]; then
            lock_gpu_clocks
        else
            unlock_gpu_clocks
        fi

        event_count=$((event_count + 1))

        # Periodic validation (every 100 events)
        if [[ $((event_count % 100)) -eq 0 ]]; then
            validate_state
        fi

    done
}

# Validate GPU count against actual state
validate_state() {
    local actual_count
    actual_count=$(get_gpu_pod_count_on_node)
    local tracked_count
    tracked_count=$(cat "${GPU_COUNT_FILE}" 2>/dev/null || echo 0)

    if [[ "${actual_count}" != "${tracked_count}" ]]; then
        log "State mismatch! Recounting... (tracked:${tracked_count} actual:${actual_count})"
        rebuild_state
    fi
}

# Rebuild GPU pod state from scratch
# Includes Running, Pending, and ContainerCreating pods
rebuild_state() {
    log "Rebuilding GPU pod state (phases: ${PHASES_WATCH})..."

    : > /tmp/chronos.gpu.pods

    # Disable set -e for this operation to prevent crashes on kubectl/grep errors
    set +e
    local count=0
    local kubectl_output
    kubectl_output=$(kubectl get pods \
        --all-namespaces \
        --field-selector=spec.nodeName="${NODE_NAME}" \
        -o custom-columns=NS:.metadata.namespace,NAME:.metadata.name,PHASE:.status.phase,GPU:.spec.containers[*].resources.requests.nvidia\\.com/gpu \
        --no-headers 2>&1)
    local kubectl_status=$?
    set -e

    if [[ ${kubectl_status} -ne 0 ]]; then
        log "WARNING: kubectl get pods failed with status ${kubectl_status}: ${kubectl_output}"
        count=0
    else
        # Filter: exclude kube-system, our own pod, and filter by phase (3rd column)
        local filtered_output
        filtered_output=$(echo "${kubectl_output}" | awk \
            '$1 != "kube-system" && \
             ! ($1 == "'"${DAEMONSET_NAMESPACE}"'" && $2 == "'"${OUR_POD_NAME}"'") && \
             ($3 == "Running" || $3 == "Pending" || $3 == "ContainerCreating") { print }' 2>/dev/null || true)

        # Process filtered output
        while IFS= read -r line; do
            [[ -z "${line}" ]] && continue
            local gpu_val
            gpu_val=$(echo "${line}" | awk '{print $NF}')

            # Validate GPU value
            [[ -z "${gpu_val}" ]] && continue
            [[ "${gpu_val}" == "<none>" ]] && continue
            [[ "${gpu_val}" == "<nil>" ]] && continue
            [[ "${gpu_val}" == "<undefined>" ]] && continue

            # Check if numeric (supports fractional: 0.5, 1, 2, etc.)
            if [[ "${gpu_val}" =~ ^[0-9]+\.?[0-9]*$ ]] || \
               [[ "${gpu_val}" =~ ^[0-9]*\.?[0-9]+$ ]]; then
                local ns name
                ns=$(echo "${line}" | awk '{print $1}')
                name=$(echo "${line}" | awk '{print $2}')
                echo "${ns}/${name}" >> /tmp/chronos.gpu.pods
                count=$((count + 1))
            fi
        done <<< "${filtered_output}"
    fi

    echo "${count}" > "${GPU_COUNT_FILE}"
    log "State rebuilt: ${count} GPU pods"

    # Take action
    if [[ ${count} -gt 0 ]]; then
        lock_gpu_clocks
    else
        unlock_gpu_clocks
    fi
}

# Initial state check before watching
initial_check() {
    log "Initial GPU pod check..."
    rebuild_state
}

# Watch pod changes on this node
# Uses polling instead of watch because kubectl get --watch doesn't provide event types (ADDED/MODIFIED/DELETED)
# When a pod is deleted, the line just disappears from watch output with no event
watch_pods() {
    log "Starting pod watch on node ${NODE_NAME}..."

    local check_interval=${CHECK_INTERVAL:-10}
    local last_count=-1

    # Disable set -e for the polling loop to prevent script from exiting on errors
    set +e

    while true; do
        # Get current GPU pod count
        local current_count
        current_count=$(get_gpu_pod_count_on_node 2>/dev/null)
        local result_status=$?

        # Check if function call succeeded (returns 0)
        if [[ ${result_status} -ne 0 ]]; then
            log "WARNING: get_gpu_pod_count_on_node failed with status ${result_status}"
        fi

        # Log if count changed
        if [[ ${current_count} -ne ${last_count} ]]; then
            log "GPU pod count changed: ${last_count} -> ${current_count}"
            last_count=${current_count}
        fi

        # Take action based on count
        if [[ ${current_count} -gt 0 ]]; then
            lock_gpu_clocks
        else
            unlock_gpu_clocks
        fi

        sleep ${check_interval}
    done
}

# Main
main() {
    log "Chronos Watch-based GPU Clock Manager"
    log "Node: ${NODE_NAME}, Namespace: ${DAEMONSET_NAMESPACE}"
    log "Release: ${DAEMONSET_RELEASE}"
    log "Run:AI support: ${RUNAI_ENABLED}"

    # Initialize
    init_state
    mkdir -p /tmp/chronos
    : > /tmp/chronos.gpu.pods

    # Trap SIGTERM for graceful shutdown - release clocks before exit
    # This handles 'helm uninstall', scale-down, node drain, etc.
    trap 'log "Received SIGTERM, releasing GPU clocks before shutdown..."; unlock_gpu_clocks; log "Shutdown complete"; exit 0' TERM

    # Get our pod name (cached for lifetime of container)
    OUR_POD_NAME=$POD_NAME
    log "Our pod: ${OUR_POD_NAME}"

    # Wait for driver
    wait_for_driver

    # Initial state check
    initial_check

    # Start watching for changes
    watch_pods
}

main "$@"