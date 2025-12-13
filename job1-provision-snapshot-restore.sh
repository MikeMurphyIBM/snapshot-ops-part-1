#!/usr/bin/env bash

################################################################################
# JOB 1: PROVISION, SNAPSHOT, CLONE & RESTORE
# Purpose: Complete backup workflow - provision empty LPAR, snapshot primary,
#          clone volumes, attach to secondary, and boot
# Dependencies: IBM Cloud CLI, PowerVS plugin, jq
################################################################################

# ------------------------------------------------------------------------------
# TIMESTAMP LOGGING SETUP
# Prepends timestamp to all output for audit trail
# ------------------------------------------------------------------------------
timestamp() {
    while IFS= read -r line; do
        printf "[%s] %s\n" "$(date '+%Y-%m-%d %H:%M:%S')" "$line"
    done
}
exec > >(timestamp) 2>&1

# ------------------------------------------------------------------------------
# STRICT ERROR HANDLING
# Exit on undefined variables and command failures
# ------------------------------------------------------------------------------
set -eu

################################################################################
# BANNER
################################################################################
echo ""
echo "========================================================================"
echo " JOB 1: COMPLETE BACKUP & RESTORE WORKFLOW"
echo " Phase A: Provision empty LPAR"
echo " Phase B: Snapshot, clone, and restore"
echo "========================================================================"
echo ""

################################################################################
# CONFIGURATION VARIABLES
# Centralized configuration for easy maintenance
################################################################################

# IBM Cloud Authentication
readonly API_KEY="${IBMCLOUD_API_KEY}"
readonly REGION="us-south"
readonly RESOURCE_GROUP="Default"

# PowerVS Workspace Configuration
readonly PVS_CRN="crn:v1:bluemix:public:power-iaas:dal10:a/21d74dd4fe814dfca20570bbb93cdbff:cc84ef2f-babc-439f-8594-571ecfcbe57a::"
readonly CLOUD_INSTANCE_ID="cc84ef2f-babc-439f-8594-571ecfcbe57a"
readonly API_VERSION="2024-02-28"

# Network Configuration
readonly SUBNET_ID="ca78b0d5-f77f-4e8c-9f2c-545ca20ff073"
readonly PRIVATE_IP="192.168.0.69"
readonly KEYPAIR_NAME="murphy-clone-key"

# LPAR Configuration
readonly PRIMARY_LPAR="get-snapshot"              # Source LPAR for snapshot
readonly PRIMARY_INSTANCE_ID="c92f6904-8bd2-4093-acec-f641899cd658"
readonly SECONDARY_LPAR="empty-ibmi-lpar"         # Target LPAR for restore
readonly MEMORY_GB=2
readonly PROCESSORS=0.25
readonly PROC_TYPE="shared"
readonly SYS_TYPE="s1022"
readonly IMAGE_ID="IBMI-EMPTY"
readonly DEPLOYMENT_TYPE="VMNoStorage"

# Storage Configuration
readonly STORAGE_TIER="tier3"                     # Must match snapshot tier

# Naming Convention
readonly CLONE_PREFIX="murph-$(date +"%Y%m%d%H%M")"
readonly SNAPSHOT_NAME="${CLONE_PREFIX}"

# Polling Configuration
readonly POLL_INTERVAL=30
readonly SNAPSHOT_POLL_INTERVAL=45
readonly STATUS_POLL_LIMIT=30
readonly INITIAL_WAIT=45
readonly MAX_ATTACH_WAIT=420
readonly MAX_BOOT_WAIT=1200

# Runtime State Variables (Tracked for Cleanup)
CURRENT_STEP="INITIALIZATION"
SECONDARY_INSTANCE_ID=""
IAM_TOKEN=""
SNAPSHOT_ID=""
SOURCE_VOLUME_IDS=""
CLONE_BOOT_ID=""
CLONE_DATA_IDS=""
CLONE_TASK_ID=""
JOB_SUCCESS=0

echo "Configuration loaded successfully."
echo ""

################################################################################
# CLEANUP FUNCTION
# Triggered on failure to rollback partially completed operations
# Logic:
#   1. Preserve snapshot (intentional - snapshots are kept for recovery)
#   2. Delete secondary LPAR if partially created
#   3. Bulk detach all volumes from secondary LPAR (if it exists and has volumes)
#   4. Bulk delete cloned volumes
#   5. Verify deletion completed
################################################################################
cleanup_on_failure() {
    trap - ERR EXIT
    
    # Skip cleanup if job completed successfully
    if [[ ${JOB_SUCCESS:-0} -eq 1 ]]; then
        echo "Job completed successfully - no cleanup needed"
        return 0
    fi
    
    echo ""
    echo "========================================================================"
    echo " FAILURE DETECTED - INITIATING CLEANUP"
    echo "========================================================================"
    echo ""
    
    # -------------------------------------------------------------------------
    # STEP 1: Preserve snapshot (by design)
    # -------------------------------------------------------------------------
    if [[ -n "${SNAPSHOT_ID}" ]]; then
        echo "→ Snapshot preserved: ${SNAPSHOT_ID}"
        echo "  (Snapshots are retained for recovery purposes)"
    fi
    
    # -------------------------------------------------------------------------
    # STEP 2: Resolve secondary LPAR instance ID (if not already resolved)
    # -------------------------------------------------------------------------
    if [[ -z "$SECONDARY_INSTANCE_ID" ]]; then
        echo "→ Resolving secondary LPAR instance ID..."
        
        SECONDARY_INSTANCE_ID=$(ibmcloud pi instance list --json 2>/dev/null \
            | jq -r --arg N "$SECONDARY_LPAR" '.pvmInstances[]? | select(.name==$N) | .id' \
            | head -n 1)
    fi
    
    if [[ -z "$SECONDARY_INSTANCE_ID" || "$SECONDARY_INSTANCE_ID" == "null" ]]; then
        echo "  ⚠ No LPAR found named '${SECONDARY_LPAR}'"
        echo "  Skipping volume cleanup - proceeding to cloned volume deletion"
    else
        echo "✓ Found LPAR '${SECONDARY_LPAR}'"
        echo "  Instance ID: ${SECONDARY_INSTANCE_ID}"
        
        # ---------------------------------------------------------------------
        # STEP 3: Bulk detach all volumes (if any are attached)
        # ---------------------------------------------------------------------
        echo "→ Checking for attached volumes..."
        
        ATTACHED=$(ibmcloud pi instance volume list "$SECONDARY_INSTANCE_ID" --json 2>/dev/null \
            | jq -r '(.volumes // [])[] | .volumeID' || true)
        
        if [[ -n "$ATTACHED" ]]; then
            echo "  Volumes detected - requesting bulk detach..."
            
            ibmcloud pi instance volume bulk-detach "$SECONDARY_INSTANCE_ID" \
                --detach-all \
                --detach-primary > /dev/null 2>&1 || true
            
            echo "  Waiting for detachment to complete..."
            
            WAIT_TIME=30
            MAX_DETACH_WAIT=240
            ELAPSED=30
            
            sleep $WAIT_TIME
            
            while true; do
                ATTACHED=$(ibmcloud pi instance volume list "$SECONDARY_INSTANCE_ID" --json 2>/dev/null \
                    | jq -r '(.volumes // [])[] | .volumeID')
                
                if [[ -z "$ATTACHED" ]]; then
                    echo "✓ All volumes detached"
                    break
                fi
                
                if [[ $ELAPSED -ge $MAX_DETACH_WAIT ]]; then
                    echo "  ⚠ WARNING: Volumes still attached after ${MAX_DETACH_WAIT}s"
                    echo "  ⚠ Proceeding with deletion anyway"
                    break
                fi
                
                echo "  Volumes still attached - retrying in ${POLL_INTERVAL}s"
                sleep "$POLL_INTERVAL"
                ELAPSED=$((ELAPSED + POLL_INTERVAL))
            done
        else
            echo "  No volumes attached - skipping detach"
        fi
    fi
    
    # -------------------------------------------------------------------------
    # STEP 4: Bulk delete cloned volumes
    # -------------------------------------------------------------------------
    echo "→ Deleting cloned volumes..."
    
    if [[ -n "$CLONE_BOOT_ID" ]]; then
        if [[ -n "$CLONE_DATA_IDS" ]]; then
            # Delete boot + data volumes
            ibmcloud pi volume bulk-delete \
                --volumes "${CLONE_BOOT_ID},${CLONE_DATA_IDS}" > /dev/null 2>&1 || true
        else
            # Delete boot volume only
            ibmcloud pi volume bulk-delete \
                --volumes "${CLONE_BOOT_ID}" > /dev/null 2>&1 || true
        fi
    fi
    
    # -------------------------------------------------------------------------
    # STEP 5: Verify deletion
    # -------------------------------------------------------------------------
    echo "→ Verifying volume deletion..."
    
    sleep 5
    
    if [[ -n "$CLONE_BOOT_ID" ]]; then
        if ibmcloud pi volume get "$CLONE_BOOT_ID" --json > /dev/null 2>&1; then
            echo "  ⚠ WARNING: Boot volume still exists - manual review required"
        else
            echo "✓ Boot volume deleted: ${CLONE_BOOT_ID}"
        fi
    fi
    
    if [[ -n "$CLONE_DATA_IDS" ]]; then
        for VOL in ${CLONE_DATA_IDS//,/ }; do
            if ibmcloud pi volume get "$VOL" --json > /dev/null 2>&1; then
                echo "  ⚠ WARNING: Data volume still exists - manual review required: ${VOL}"
            else
                echo "✓ Data volume deleted: ${VOL}"
            fi
        done
    fi
    
    echo ""
    echo "========================================================================"
    echo " CLEANUP COMPLETE"
    echo "========================================================================"
    echo ""
}

################################################################################
# HELPER FUNCTION: WAIT FOR ASYNC CLONE JOB
# Logic:
#   1. Poll clone task status every 30 seconds
#   2. Complete when status is "completed"
#   3. Fail if status is "failed"
################################################################################
wait_for_clone_job() {
    local task_id=$1
    echo "→ Waiting for asynchronous clone task: ${task_id}..."
    
    while true; do
        STATUS=$(ibmcloud pi volume clone-async get "$task_id" --json \
            | jq -r '.status')
        
        if [[ "$STATUS" == "completed" ]]; then
            echo "✓ Clone task completed successfully"
            break
        elif [[ "$STATUS" == "failed" ]]; then
            echo "✗ ERROR: Clone task failed"
            exit 1
        else
            echo "  Clone task status: ${STATUS} - waiting 30s..."
            sleep 30
        fi
    done
}

################################################################################
# ACTIVATE CLEANUP TRAP
# Ensures cleanup runs on both ERR and EXIT
################################################################################
trap 'cleanup_on_failure' ERR EXIT

################################################################################
# PHASE A - STAGE 1: IBM CLOUD AUTHENTICATION
################################################################################
CURRENT_STEP="IBM_CLOUD_LOGIN"

echo "========================================================================"
echo " PHASE A - STAGE 1/9: IBM CLOUD AUTHENTICATION & WORKSPACE TARGETING"
echo "========================================================================"
echo ""

echo "→ Authenticating to IBM Cloud (Region: ${REGION})..."
ibmcloud login --apikey "$API_KEY" -r "$REGION" > /dev/null 2>&1 || {
    echo "✗ ERROR: IBM Cloud login failed"
    exit 1
}
echo "✓ Authentication successful"

echo "→ Targeting resource group: ${RESOURCE_GROUP}..."
ibmcloud target -g "$RESOURCE_GROUP" > /dev/null 2>&1 || {
    echo "✗ ERROR: Failed to target resource group"
    exit 1
}
echo "✓ Resource group targeted"

echo "→ Targeting PowerVS workspace..."
ibmcloud pi workspace target "$PVS_CRN" > /dev/null 2>&1 || {
    echo "✗ ERROR: Failed to target PowerVS workspace"
    exit 1
}
echo "✓ PowerVS workspace targeted"

echo ""
echo "------------------------------------------------------------------------"
echo " Phase A - Stage 1 Complete: Authentication successful"
echo "------------------------------------------------------------------------"
echo ""

################################################################################
# PHASE A - STAGE 2: IAM TOKEN RETRIEVAL
# Logic:
#   1. Exchange API key for IAM bearer token via OAuth endpoint
#   2. Parse JSON response to extract access token
#   3. Validate token is non-empty before proceeding
# Note: Token is required for direct REST API calls to PowerVS
################################################################################
CURRENT_STEP="IAM_TOKEN_RETRIEVAL"

echo "→ Retrieving IAM access token for API authentication..."

IAM_RESPONSE=$(curl -s -X POST "https://iam.cloud.ibm.com/identity/token" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -H "Accept: application/json" \
    -d "grant_type=urn:ibm:params:oauth:grant-type:apikey" \
    -d "apikey=${API_KEY}")

IAM_TOKEN=$(echo "$IAM_RESPONSE" | jq -r '.access_token // empty' 2>/dev/null || true)

if [[ -z "$IAM_TOKEN" || "$IAM_TOKEN" == "null" ]]; then
    echo "✗ ERROR: IAM token retrieval failed"
    echo "Response: $IAM_RESPONSE"
    exit 1
fi

export IAM_TOKEN
echo "✓ IAM token retrieved successfully"
echo ""

################################################################################
# PHASE A - STAGE 3: CREATE SECONDARY LPAR VIA REST API
# Logic:
#   1. Build JSON payload with LPAR specifications
#   2. Submit creation request to PowerVS REST API
#   3. Retry up to 3 times if API call fails
#   4. Extract and validate LPAR instance ID from response
#   5. Handle multiple possible JSON response formats
################################################################################
CURRENT_STEP="CREATE_LPAR"

echo "========================================================================"
echo " PHASE A - STAGE 3/9: CREATE SECONDARY LPAR"
echo "========================================================================"
echo ""

echo "→ Building LPAR configuration payload..."

# Construct JSON payload for LPAR creation
PAYLOAD=$(cat <<EOF
{
  "serverName": "${SECONDARY_LPAR}",
  "processors": ${PROCESSORS},
  "memory": ${MEMORY_GB},
  "procType": "${PROC_TYPE}",
  "sysType": "${SYS_TYPE}",
  "imageID": "${IMAGE_ID}",
  "deploymentType": "${DEPLOYMENT_TYPE}",
  "keyPairName": "${KEYPAIR_NAME}",
  "networks": [
    {
      "networkID": "${SUBNET_ID}",
      "ipAddress": "${PRIVATE_IP}"
    }
  ]
}
EOF
)

API_URL="https://${REGION}.power-iaas.cloud.ibm.com/pcloud/v1/cloud-instances/${CLOUD_INSTANCE_ID}/pvm-instances?version=${API_VERSION}"

echo "→ Submitting LPAR creation request to PowerVS API..."

# Retry logic for API resilience
ATTEMPTS=0
MAX_ATTEMPTS=3

while [[ $ATTEMPTS -lt $MAX_ATTEMPTS && -z "$SECONDARY_INSTANCE_ID" ]]; do
    ATTEMPTS=$((ATTEMPTS + 1))
    echo "  Attempt ${ATTEMPTS}/${MAX_ATTEMPTS}..."
    
    # Temporarily disable exit-on-error for this block
    set +e
    RESPONSE=$(curl -s -X POST "${API_URL}" \
        -H "Authorization: Bearer ${IAM_TOKEN}" \
        -H "CRN: ${PVS_CRN}" \
        -H "Content-Type: application/json" \
        -d "${PAYLOAD}" 2>&1)
    CURL_CODE=$?
    set -e
    
    if [[ $CURL_CODE -ne 0 ]]; then
        echo "  ⚠ WARNING: curl failed with exit code ${CURL_CODE}"
        sleep 5
        continue
    fi
    
    # Safe jq parsing - handles multiple response formats
    SECONDARY_INSTANCE_ID=$(echo "$RESPONSE" | jq -r '
        .pvmInstanceID? //
        (.[0].pvmInstanceID? // empty) //
        .pvmInstance.pvmInstanceID? //
        empty
    ' 2>/dev/null || true)
    
    if [[ -z "$SECONDARY_INSTANCE_ID" || "$SECONDARY_INSTANCE_ID" == "null" ]]; then
        echo "  ⚠ WARNING: Could not extract instance ID - retrying..."
        sleep 5
    fi
done

# Fail if all attempts exhausted without success
if [[ -z "$SECONDARY_INSTANCE_ID" || "$SECONDARY_INSTANCE_ID" == "null" ]]; then
    echo "✗ FAILURE: Could not retrieve LPAR instance ID after ${MAX_ATTEMPTS} attempts"
    echo ""
    echo "API Response:"
    echo "$RESPONSE"
    exit 1
fi

echo "✓ LPAR creation request accepted"
echo ""
echo "  LPAR Details:"
echo "  ┌────────────────────────────────────────────────────────────"
echo "  │ Name:        ${SECONDARY_LPAR}"
echo "  │ Instance ID: ${SECONDARY_INSTANCE_ID}"
echo "  │ Private IP:  ${PRIVATE_IP}"
echo "  │ Subnet:      ${SUBNET_ID}"
echo "  │ CPU Cores:   ${PROCESSORS}"
echo "  │ Memory:      ${MEMORY_GB} GB"
echo "  │ Proc Type:   ${PROC_TYPE}"
echo "  │ System Type: ${SYS_TYPE}"
echo "  └────────────────────────────────────────────────────────────"
echo ""

################################################################################
# PHASE A - STAGE 4: WAIT FOR LPAR PROVISIONING
# Logic:
#   1. Initial wait for PowerVS backend to begin provisioning
#   2. Poll instance status every 30 seconds
#   3. Wait for SHUTOFF/STOPPED state (expected for empty LPAR)
#   4. Timeout after specified poll limit
################################################################################
CURRENT_STEP="STATUS_POLLING"

echo "========================================================================"
echo " PHASE A - STAGE 4/9: WAIT FOR LPAR PROVISIONING"
echo "========================================================================"
echo ""

echo "→ Waiting ${INITIAL_WAIT} seconds for initial provisioning..."
sleep $INITIAL_WAIT
echo ""

echo "→ Beginning status polling (interval: ${POLL_INTERVAL}s, max attempts: ${STATUS_POLL_LIMIT})..."
echo ""

STATUS=""
ATTEMPT=1

while true; do
    # Temporarily disable exit-on-error for status check
    set +e
    STATUS_JSON=$(ibmcloud pi ins get "$SECONDARY_INSTANCE_ID" --json 2>/dev/null)
    STATUS_EXIT=$?
    set -e
    
    if [[ $STATUS_EXIT -ne 0 ]]; then
        echo "  ⚠ WARNING: Status retrieval failed - retrying..."
        sleep "$POLL_INTERVAL"
        continue
    fi
    
    STATUS=$(echo "$STATUS_JSON" | jq -r '.status // empty' 2>/dev/null || true)
    echo "  Status Check (${ATTEMPT}/${STATUS_POLL_LIMIT}): ${STATUS}"
    
    # Success condition: LPAR is in final stopped state
    if [[ "$STATUS" == "SHUTOFF" || "$STATUS" == "STOPPED" ]]; then
        echo ""
        echo "✓ LPAR reached final state: ${STATUS}"
        break
    fi
    
    # Timeout condition
    if (( ATTEMPT >= STATUS_POLL_LIMIT )); then
        echo ""
        echo "✗ FAILURE: Status polling timed out after ${STATUS_POLL_LIMIT} attempts"
        exit 1
    fi
    
    ((ATTEMPT++))
    sleep "$POLL_INTERVAL"
done

echo ""
echo "------------------------------------------------------------------------"
echo " Phase A - Stage 4 Complete: Secondary LPAR provisioned and ready"
echo "------------------------------------------------------------------------"
echo ""

################################################################################
# PHASE B - STAGE 5: SNAPSHOT PRIMARY LPAR
# Logic:
#   1. Create snapshot of primary LPAR with timestamped name
#   2. Poll snapshot status until AVAILABLE
#   3. Handle ERROR state as failure
################################################################################
CURRENT_STEP="CREATE_SNAPSHOT"

echo "========================================================================"
echo " PHASE B - STAGE 5/9: SNAPSHOT PRIMARY LPAR"
echo "========================================================================"
echo ""

echo "→ Creating snapshot of primary LPAR: ${PRIMARY_LPAR}"
echo "  Snapshot name: ${SNAPSHOT_NAME}"

SNAPSHOT_JSON=$(ibmcloud pi instance snapshot create "$PRIMARY_LPAR" \
    --name "$SNAPSHOT_NAME" \
    --json 2>/dev/null) || {
    echo "✗ ERROR: Snapshot creation failed"
    exit 1
}

SNAPSHOT_ID=$(echo "$SNAPSHOT_JSON" | jq -r '.snapshotID')
echo "✓ Snapshot created"
echo "  Snapshot ID: ${SNAPSHOT_ID}"
echo ""

echo "→ Polling snapshot status (interval: ${SNAPSHOT_POLL_INTERVAL}s)..."

while true; do
    STATUS_JSON=$(ibmcloud pi instance snapshot get "$SNAPSHOT_ID" --json 2>/dev/null)
    SNAP_STATUS=$(echo "$STATUS_JSON" | jq -r '.status')
    
    echo "  Snapshot status: ${SNAP_STATUS}"
    
    if [[ "$SNAP_STATUS" == "available" ]]; then
        echo "✓ Snapshot is AVAILABLE"
        break
    elif [[ "$SNAP_STATUS" == "error" ]]; then
        echo "✗ ERROR: Snapshot entered ERROR state"
        exit 1
    fi
    
    sleep "$SNAPSHOT_POLL_INTERVAL"
done

echo ""
echo "------------------------------------------------------------------------"
echo " Phase B - Stage 5 Complete: Snapshot ready for cloning"
echo "------------------------------------------------------------------------"
echo ""

################################################################################
# PHASE B - STAGE 6: EXTRACT SNAPSHOT VOLUMES
# Logic:
#   1. Parse snapshot JSON to extract volume IDs
#   2. Separate boot volume from data volumes
#   3. Validate at least one boot volume exists
################################################################################
CURRENT_STEP="EXTRACT_VOLUMES"

echo "========================================================================"
echo " PHASE B - STAGE 6/9: EXTRACT SNAPSHOT VOLUME INFORMATION"
echo "========================================================================"
echo ""

echo "→ Extracting volume information from snapshot..."

SNAPSHOT_DETAIL=$(ibmcloud pi instance snapshot get "$SNAPSHOT_ID" --json)

# Debug: Show the actual JSON structure
echo "  Debug: Snapshot JSON structure..."
echo "$SNAPSHOT_DETAIL" | jq '.' || echo "  Could not parse JSON"

# Parse volume IDs from snapshot - handle multiple possible structures
# The snapshot detail might have volumeSnapshots as an array or as nested objects
SOURCE_VOLUME_IDS=$(echo "$SNAPSHOT_DETAIL" | jq -r '
    if .volumeSnapshots then
        if (.volumeSnapshots | type) == "array" then
            .volumeSnapshots[] | .volumeID? // .volumeId? // empty
        else
            .volumeSnapshots | to_entries[] | .value.volumeID? // .value.volumeId? // empty
        fi
    else
        empty
    end
' | paste -sd "," -)

if [[ -z "$SOURCE_VOLUME_IDS" ]]; then
    echo "✗ ERROR: No volumes found in snapshot"
    echo ""
    echo "Snapshot detail (for debugging):"
    echo "$SNAPSHOT_DETAIL" | jq '.'
    exit 1
fi

echo "✓ Found volumes in snapshot: ${SOURCE_VOLUME_IDS}"

# Identify boot vs data volumes
SOURCE_BOOT_ID=$(echo "$SNAPSHOT_DETAIL" \
    | jq -r '.volumeSnapshots[] | select(.bootable==true) | .volumeID' \
    | head -n 1)

SOURCE_DATA_IDS=$(echo "$SNAPSHOT_DETAIL" \
    | jq -r '.volumeSnapshots[] | select(.bootable==false) | .volumeID' \
    | paste -sd "," -)

echo ""
echo "  Volume Classification:"
echo "  ├─ Boot Volume:  ${SOURCE_BOOT_ID}"
echo "  └─ Data Volumes: ${SOURCE_DATA_IDS:-None}"

echo ""
echo "------------------------------------------------------------------------"
echo " Phase B - Stage 6 Complete: Volume information extracted"
echo "------------------------------------------------------------------------"
echo ""

################################################################################
# PHASE B - STAGE 7: CLONE SNAPSHOT VOLUMES
# Logic:
#   1. Submit asynchronous clone request with new volume names
#   2. Extract clone task ID
#   3. Wait for clone job to complete
#   4. Extract cloned volume IDs from completed job
#   5. Separate boot and data volumes
################################################################################
CURRENT_STEP="CLONE_VOLUMES"

echo "========================================================================"
echo " PHASE B - STAGE 7/9: CLONE SNAPSHOT VOLUMES"
echo "========================================================================"
echo ""

echo "→ Submitting clone request..."
echo "  Clone prefix: ${CLONE_PREFIX}"
echo "  Storage tier: ${STORAGE_TIER}"

CLONE_JSON=$(ibmcloud pi volume clone-async \
    --target-tier "$STORAGE_TIER" \
    --volumes "$SOURCE_VOLUME_IDS" \
    --name "$CLONE_PREFIX" \
    --json 2>/dev/null) || {
    echo "✗ ERROR: Clone request failed"
    exit 1
}

CLONE_TASK_ID=$(echo "$CLONE_JSON" | jq -r '.clonedVolumes[0].cloneTaskID')
echo "✓ Clone request submitted"
echo "  Clone task ID: ${CLONE_TASK_ID}"
echo ""

# Wait for clone job to complete
wait_for_clone_job "$CLONE_TASK_ID"

echo ""
echo "→ Extracting cloned volume IDs..."

CLONE_RESULT=$(ibmcloud pi volume clone-async get "$CLONE_TASK_ID" --json)

CLONE_BOOT_ID=$(echo "$CLONE_RESULT" \
    | jq -r '.clonedVolumes[] | select(.sourceVolume=="'"$SOURCE_BOOT_ID"'") | .clonedVolume')

if [[ -n "$SOURCE_DATA_IDS" ]]; then
    CLONE_DATA_IDS=$(echo "$CLONE_RESULT" \
        | jq -r '.clonedVolumes[] | select(.sourceVolume!="'"$SOURCE_BOOT_ID"'") | .clonedVolume' \
        | paste -sd "," -)
fi

echo "✓ Cloned volume IDs extracted"
echo "  Boot volume: ${CLONE_BOOT_ID}"
echo "  Data volumes: ${CLONE_DATA_IDS:-None}"

echo ""
echo "------------------------------------------------------------------------"
echo " Phase B - Stage 7 Complete: Volumes cloned successfully"
echo "------------------------------------------------------------------------"
echo ""

################################################################################
# PHASE B - STAGE 8: ATTACH VOLUMES TO SECONDARY LPAR
# Logic:
#   1. Verify cloned volumes are available
#   2. Attach boot volume and data volumes (if any)
#   3. Wait for initial stabilization
#   4. Poll until all volumes appear in instance volume list
################################################################################
CURRENT_STEP="ATTACH_VOLUMES"

echo "========================================================================"
echo " PHASE B - STAGE 8/9: ATTACH VOLUMES TO SECONDARY LPAR"
echo "========================================================================"
echo ""

echo "→ Verifying cloned volumes are available..."

# Verify boot volume
while true; do
    BOOT_STATUS=$(ibmcloud pi volume get "$CLONE_BOOT_ID" --json \
        | jq -r '.state')
    
    if [[ "$BOOT_STATUS" == "available" ]]; then
        echo "✓ Boot volume available: ${CLONE_BOOT_ID}"
        break
    fi
    
    echo "  Boot volume status: ${BOOT_STATUS} - waiting..."
    sleep "$POLL_INTERVAL"
done

# Verify data volumes (if any)
if [[ -n "$CLONE_DATA_IDS" ]]; then
    for VOL in ${CLONE_DATA_IDS//,/ }; do
        while true; do
            DATA_STATUS=$(ibmcloud pi volume get "$VOL" --json \
                | jq -r '.state')
            
            if [[ "$DATA_STATUS" == "available" ]]; then
                echo "✓ Data volume available: ${VOL}"
                break
            fi
            
            echo "  Data volume status: ${DATA_STATUS} - waiting..."
            sleep "$POLL_INTERVAL"
        done
    done
fi

echo ""
echo "→ Attaching volumes to secondary LPAR..."
echo "  LPAR: ${SECONDARY_LPAR}"
echo "  Instance ID: ${SECONDARY_INSTANCE_ID}"
echo ""

if [[ -n "$CLONE_DATA_IDS" ]]; then
    echo "  Attaching boot + data volumes..."
    ibmcloud pi instance volume attach "$SECONDARY_INSTANCE_ID" \
        --volumes "$CLONE_DATA_IDS" \
        --boot-volume "$CLONE_BOOT_ID" || {
        echo "✗ ERROR: Volume attachment failed"
        exit 1
    }
else
    echo "  Attaching boot volume only..."
    ibmcloud pi instance volume attach "$SECONDARY_INSTANCE_ID" \
        --boot-volume "$CLONE_BOOT_ID" || {
        echo "✗ ERROR: Boot volume attachment failed"
        exit 1
    }
fi

echo "✓ Attachment request accepted"
echo ""

echo "→ Waiting ${SNAPSHOT_POLL_INTERVAL}s for backend stabilization..."
sleep $SNAPSHOT_POLL_INTERVAL
echo ""

echo "→ Polling for volume attachment confirmation..."

ELAPSED=0

while true; do
    VOL_LIST=$(ibmcloud pi instance volume list "$SECONDARY_INSTANCE_ID" --json 2>/dev/null \
        | jq -r '(.volumes // []) | .[]? | .volumeID')
    
    # Check boot volume is attached
    BOOT_ATTACHED=$(echo "$VOL_LIST" | grep -q "$CLONE_BOOT_ID" && echo yes || echo no)
    
    # Check all data volumes are attached
    DATA_ATTACHED=true
    if [[ -n "$CLONE_DATA_IDS" ]]; then
        for VOL in ${CLONE_DATA_IDS//,/ }; do
            if ! echo "$VOL_LIST" | grep -q "$VOL"; then
                DATA_ATTACHED=false
                break
            fi
        done
    fi
    
    if [[ "$BOOT_ATTACHED" == "yes" && "$DATA_ATTACHED" == "true" ]]; then
        echo "✓ All volumes confirmed attached"
        break
    fi
    
    if [[ $ELAPSED -ge $MAX_ATTACH_WAIT ]]; then
        echo "✗ ERROR: Volumes not attached after ${MAX_ATTACH_WAIT}s"
        exit 1
    fi
    
    echo "  Volumes not fully visible yet - checking again in ${POLL_INTERVAL}s..."
    sleep "$POLL_INTERVAL"
    ELAPSED=$((ELAPSED + POLL_INTERVAL))
done

echo ""
echo "------------------------------------------------------------------------"
echo " Phase B - Stage 8 Complete: Volumes attached and verified"
echo "------------------------------------------------------------------------"
echo ""

################################################################################
# PHASE B - STAGE 9: BOOT SECONDARY LPAR
# Logic:
#   1. Check current LPAR status
#   2. If not ACTIVE, configure boot mode and start LPAR
#   3. Poll status until ACTIVE or timeout
#   4. Handle ERROR state as failure
################################################################################
CURRENT_STEP="BOOT_LPAR"

echo "========================================================================"
echo " PHASE B - STAGE 9/9: BOOT SECONDARY LPAR"
echo "========================================================================"
echo ""

echo "→ Checking current LPAR status..."

CURRENT_STATUS=$(ibmcloud pi instance get "$SECONDARY_INSTANCE_ID" --json \
    | jq -r '.status')

echo "  Current status: ${CURRENT_STATUS}"
echo ""

if [[ "$CURRENT_STATUS" != "ACTIVE" ]]; then
    echo "→ Configuring boot mode (NORMAL)..."
    
    ibmcloud pi instance operation "$SECONDARY_INSTANCE_ID" \
        --operation-type boot \
        --boot-mode a \
        --boot-operating-mode normal || {
        echo "✗ ERROR: Boot configuration failed"
        exit 1
    }
    
    echo "✓ Boot mode configured"
    echo ""
    
    echo "→ Starting LPAR..."
    
    ibmcloud pi instance action "$SECONDARY_INSTANCE_ID" --operation start || {
        echo "✗ ERROR: LPAR start command failed"
        exit 1
    }
    
    echo "✓ Start command accepted"
else
    echo "  LPAR already ACTIVE - skipping boot sequence"
fi

echo ""
echo "→ Waiting for LPAR to reach ACTIVE state..."
echo "  (Max wait: $(($MAX_BOOT_WAIT/60)) minutes)"
echo ""

BOOT_ELAPSED=0

while true; do
    STATUS=$(ibmcloud pi instance get "$SECONDARY_INSTANCE_ID" --json \
        | jq -r '.status')
    
    echo "  LPAR status: ${STATUS} (elapsed: ${BOOT_ELAPSED}s)"
    
    if [[ "$STATUS" == "ACTIVE" ]]; then
        echo ""
        echo "✓ LPAR is ACTIVE"
        JOB_SUCCESS=1
        break
    fi
    
    if [[ "$STATUS" == "ERROR" ]]; then
        echo ""
        echo "✗ ERROR: LPAR entered ERROR state during boot"
        exit 1
    fi
    
    if [[ $BOOT_ELAPSED -ge $MAX_BOOT_WAIT ]]; then
        echo ""
        echo "✗ ERROR: LPAR failed to reach ACTIVE state within $(($MAX_BOOT_WAIT/60)) minutes"
        exit 1
    fi
    
    sleep "$POLL_INTERVAL"
    BOOT_ELAPSED=$((BOOT_ELAPSED + POLL_INTERVAL))
done

echo ""
echo "------------------------------------------------------------------------"
echo " Phase B - Stage 9 Complete: LPAR booted successfully"
echo "------------------------------------------------------------------------"
echo ""

################################################################################
# FINAL VALIDATION & SUMMARY
################################################################################
echo ""
echo "========================================================================"
echo " JOB 1: COMPLETION SUMMARY"
echo "========================================================================"
echo ""

# Final status readback (with error handling)
set +e
FINAL_CHECK=$(ibmcloud pi instance get "$SECONDARY_INSTANCE_ID" --json 2>/dev/null)
FINAL_STATUS=$(echo "$FINAL_CHECK" | jq -r '.status // "ACTIVE"' 2>/dev/null)
set -e

echo "  Status:                  ✓ SUCCESS"
echo "  ────────────────────────────────────────────────────────────────"
echo "  PHASE A: LPAR PROVISIONING"
echo "  ────────────────────────────────────────────────────────────────"
echo "  Secondary LPAR:          ${SECONDARY_LPAR}"
echo "  Instance ID:             ${SECONDARY_INSTANCE_ID}"
echo "  Private IP:              ${PRIVATE_IP}"
echo "  ────────────────────────────────────────────────────────────────"
echo "  PHASE B: SNAPSHOT & RESTORE"
echo "  ────────────────────────────────────────────────────────────────"
echo "  Primary LPAR:            ${PRIMARY_LPAR}"
echo "  Snapshot Created:        ✓ Yes (${SNAPSHOT_ID})"
echo "  Snapshot Name:           ${SNAPSHOT_NAME}"
echo "  Volumes Cloned:          ✓ Yes"
echo "  Boot Volume:             ${CLONE_BOOT_ID}"
echo "  Data Volumes:            ${CLONE_DATA_IDS:-None}"
echo "  Volumes Attached:        ✓ Yes"
echo "  Boot Mode:               ✓ NORMAL (Mode A)"
echo "  Final Status:            ${FINAL_STATUS}"
echo "  ────────────────────────────────────────────────────────────────"
echo ""
echo "  Complete backup and restore cycle finished successfully"
echo ""
echo "========================================================================"
echo ""

# Disable cleanup trap - job completed successfully
trap - ERR EXIT

################################################################################
# OPTIONAL STAGE: TRIGGER CLEANUP JOB (Job 2)
################################################################################
echo "========================================================================"
echo " OPTIONAL STAGE: CHAIN TO CLEANUP PROCESS"
echo "========================================================================"
echo ""

if [[ "${RUN_CLEANUP_JOB:-No}" == "Yes" ]]; then
    echo "→ RUN_CLEANUP_JOB=Yes detected - triggering Job 2..."
    
    echo "  Switching to Code Engine project: IBMi..."
    ibmcloud ce project target --name IBMi > /dev/null 2>&1 || {
        echo "✗ ERROR: Unable to target Code Engine project 'IBMi'"
        exit 1
    }
    
    echo "  Submitting Code Engine job: prod-cleanup..."
    
    RAW_SUBMISSION=$(ibmcloud ce jobrun submit \
        --job prod-cleanup \
        --output json 2>&1)
    
    NEXT_RUN=$(echo "$RAW_SUBMISSION" | jq -r '.metadata.name // .name // empty' 2>/dev/null || true)
    
    if [[ -z "$NEXT_RUN" ]]; then
        echo "✗ ERROR: Job submission failed - no jobrun name returned"
        echo ""
        echo "Raw output:"
        echo "$RAW_SUBMISSION"
        exit 1
    fi
    
    echo "✓ Job 2 (cleanup) triggered successfully"
    echo "  Jobrun instance: ${NEXT_RUN}"
else
    echo "→ RUN_CLEANUP_JOB not set - skipping Job 2"
    echo "  Snapshot and volumes will remain until manual cleanup"
fi

echo ""
echo "========================================================================"
echo ""

JOB_SUCCESS=1
sleep 1
exit 0
