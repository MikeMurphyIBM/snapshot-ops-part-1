#!/usr/bin/env bash

################################################################################
# JOB 1: EMPTY IBMi LPAR PROVISIONING
# Purpose: Create an empty IBMi LPAR for snapshot/clone and backup operations
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
echo "============================================================================"
echo " JOB 1: EMPTY IBMi LPAR PROVISIONING"
echo " Purpose: Create snapshot-ready LPAR for backup operations"
echo "============================================================================"
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
readonly PVS_CRN="crn:v1:bluemix:public:power-iaas:dal10:a/db1a8b544a184fd7ac339c243684a9b7:973f4d55-9056-4848-8ed0-4592093161d2::" #workspace crn
readonly CLOUD_INSTANCE_ID="973f4d55-9056-4848-8ed0-4592093161d2" #workspace ID
readonly API_VERSION="2024-02-28"

# Network Configuration
readonly SUBNET_ID="9b9c414e-aa95-41aa-8ed2-40141e0c42fd"
readonly PRIVATE_IP="192.168.10.35"
readonly KEYPAIR_NAME="murph2"

# LPAR Specifications
readonly LPAR_NAME="murphy-prod-clone"
readonly MEMORY_GB=2
readonly PROCESSORS=0.25
readonly PROC_TYPE="shared"
readonly SYS_TYPE="s1022"
readonly IMAGE_ID="IBMI-EMPTY"
readonly DEPLOYMENT_TYPE="VMNoStorage"

# Polling Configuration
readonly POLL_INTERVAL=30
readonly STATUS_POLL_LIMIT=30
readonly INITIAL_WAIT=45

# Runtime State Variables
CURRENT_STEP="INITIALIZATION"
LPAR_INSTANCE_ID=""
IAM_TOKEN=""
JOB_SUCCESS=0

echo "Configuration loaded successfully."
echo ""

################################################################################
# ROLLBACK FUNCTION
# Triggered on any unhandled error to cleanup partial resources
# Logic:
#   1. Identifies the failed step for debugging
#   2. Attempts to delete partially created LPAR if instance ID exists
#   3. Logs cleanup status and exits with failure code
################################################################################
rollback() {
    echo ""
    echo "========================================================================"
    echo " ROLLBACK EVENT INITIATED"
    echo "========================================================================"
    echo "Error occurred in step: ${CURRENT_STEP}"
    echo "------------------------------------------------------------------------"
    
    # Only attempt LPAR cleanup if we got far enough to create one
    if [[ -n "${LPAR_INSTANCE_ID}" ]]; then
        echo "Attempting cleanup of partially created LPAR: ${LPAR_NAME}"
        echo "Instance ID: ${LPAR_INSTANCE_ID}"
        
        if ibmcloud pi ins delete "$LPAR_INSTANCE_ID" 2>/dev/null; then
            echo "✓ LPAR cleanup successful"
        else
            echo "✗ LPAR cleanup failed - manual intervention required"
        fi
    else
        echo "No LPAR instance ID found - skipping resource cleanup"
    fi
    
    echo ""
    echo "Rollback complete. Exiting with failure status."
    echo "========================================================================"
    exit 1
}

# Activate rollback trap for error handling
trap rollback ERR

################################################################################
# STAGE 1: IBM CLOUD AUTHENTICATION & WORKSPACE TARGETING
# Logic:
#   1. Authenticate using API key
#   2. Target the specified resource group
#   3. Target the PowerVS workspace for all subsequent operations
################################################################################
CURRENT_STEP="IBM_CLOUD_LOGIN"

echo "========================================================================"
echo " STAGE 1/2: IBM CLOUD AUTHENTICATION & WORKSPACE TARGETING"
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
echo " Stage 1 Complete: Ready for LPAR provisioning"
echo "------------------------------------------------------------------------"
echo ""

################################################################################
# STAGE 1.5: IAM TOKEN RETRIEVAL
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
# STAGE 2: LPAR CREATION VIA REST API
# Logic:
#   1. Build JSON payload with LPAR specifications
#   2. Submit creation request to PowerVS REST API
#   3. Retry up to 3 times if API call fails
#   4. Extract and validate LPAR instance ID from response
#   5. Handle multiple possible JSON response formats
################################################################################
CURRENT_STEP="CREATE_LPAR"

echo "========================================================================"
echo " STAGE 2/2: LPAR CREATION & DEPLOYMENT"
echo "========================================================================"
echo ""

echo "→ Building LPAR configuration payload..."
echo "PAYLOAD"

# Construct JSON payload for LPAR creation
# Added "ibmiCss": true to enable IBM i Cloud Storage Solutions license
PAYLOAD=$(cat <<EOF
{
  "serverName": "${LPAR_NAME}",
  "processors": ${PROCESSORS},
  "memory": ${MEMORY_GB},
  "procType": "${PROC_TYPE}",
  "sysType": "${SYS_TYPE}",
  "imageID": "${IMAGE_ID}",
  "deploymentType": "${DEPLOYMENT_TYPE}",
  "ibmiCss": true,
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

: << Comment

# Construct JSON payload for LPAR creation
PAYLOAD=$(cat <<EOF
{
  "serverName": "${LPAR_NAME}",
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
comment

API_URL="https://${REGION}.power-iaas.cloud.ibm.com/pcloud/v1/cloud-instances/${CLOUD_INSTANCE_ID}/pvm-instances?version=${API_VERSION}"

echo "→ Submitting LPAR creation request to PowerVS API..."

# Retry logic for API resilience
ATTEMPTS=0
MAX_ATTEMPTS=3


while [[ $ATTEMPTS -lt $MAX_ATTEMPTS && -z "$LPAR_INSTANCE_ID" ]]; do
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
    # Response can be: {pvmInstanceID: "..."}, [{pvmInstanceID: "..."}], or {pvmInstance: {pvmInstanceID: "..."}}
    LPAR_INSTANCE_ID=$(echo "$RESPONSE" | jq -r '
        .pvmInstanceID? //
        (.[0].pvmInstanceID? // empty) //
        .pvmInstance.pvmInstanceID? //
        empty
    ' 2>/dev/null || true)
    
    if [[ -z "$LPAR_INSTANCE_ID" || "$LPAR_INSTANCE_ID" == "null" ]]; then
        echo "  ⚠ WARNING: Could not extract instance ID - retrying..."
        sleep 5
    fi
done

# Fail if all attempts exhausted without success
if [[ -z "$LPAR_INSTANCE_ID" || "$LPAR_INSTANCE_ID" == "null" ]]; then
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
echo "  │ Name:        ${LPAR_NAME}"
echo "  │ Instance ID: ${LPAR_INSTANCE_ID}"
echo "  │ Private IP:  ${PRIVATE_IP}"
echo "  │ Subnet:      ${SUBNET_ID}"
echo "  │ CPU Cores:   ${PROCESSORS}"
echo "  │ Memory:      ${MEMORY_GB} GB"
echo "  │ Proc Type:   ${PROC_TYPE}"
echo "  │ System Type: ${SYS_TYPE}"
echo "  └────────────────────────────────────────────────────────────"
echo ""

################################################################################
# STAGE 2.5: PROVISIONING WAIT & STATUS POLLING
# Logic:
#   1. Initial wait for PowerVS backend to begin provisioning
#   2. Poll instance status every 30 seconds
#   3. Wait for SHUTOFF/STOPPED state (expected for empty LPAR)
#   4. Timeout after specified poll limit
################################################################################
CURRENT_STEP="STATUS_POLLING"

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
    STATUS_JSON=$(ibmcloud pi ins get "$LPAR_INSTANCE_ID" --json 2>/dev/null)
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
echo " Stage 2 Complete: LPAR provisioned and ready"
echo "------------------------------------------------------------------------"
echo ""

################################################################################
# COMPLETION SUMMARY
################################################################################
echo ""
echo "========================================================================"
echo " JOB 1: COMPLETION SUMMARY"
echo "========================================================================"
echo ""
echo "  Status:          ✓ SUCCESS"
echo "  LPAR Name:       ${LPAR_NAME}"
echo "  Instance ID:     ${LPAR_INSTANCE_ID}"
echo "  Final Status:    ${STATUS}"
echo "  Private IP:      ${PRIVATE_IP}"
echo "  Subnet:          ${SUBNET_ID}"
echo ""
echo "  Next Steps:"
echo "  - LPAR is in ${STATUS} state and ready for volume attachment"
echo "  - Run Job 2 (volume cloning) to restore OS and data"
echo ""
echo "========================================================================"
echo ""

# Disable rollback trap - job completed successfully
trap - ERR

################################################################################
# OPTIONAL STAGE: TRIGGER NEXT JOB (Job 2)
# Logic:
#   1. Check if RUN_ATTACH_JOB environment variable is set to "Yes"
#   2. If yes, switch to Code Engine project and submit Job 2
#   3. Capture and validate jobrun submission
################################################################################
echo "========================================================================"
echo " OPTIONAL STAGE: CHAIN TO VOLUME CLONE PROCESS"
echo "========================================================================"
echo ""

if [[ "${RUN_ATTACH_JOB:-No}" == "Yes" ]]; then
    echo "→ Proceed to Volume Cloning has been requested - triggering Job 2..."

    echo " targeting new resource group.."
    ibmcloud target -g cloud-techsales
    
    echo "  Switching to Code Engine project: usnm-project..."
    ibmcloud ce project target --name usnm-project > /dev/null 2>&1 || {
        echo "✗ ERROR: Unable to target Code Engine project 'usnm-project'"
        exit 1
    }
    
    echo "  Submitting Code Engine job: snap-ops-2..."
    
    # Capture full output (stdout + stderr)
    RAW_SUBMISSION=$(ibmcloud ce jobrun submit \
        --job snap-ops-2 \
        --output json 2>&1)
    
    # Extract jobrun name from response
    NEXT_RUN=$(echo "$RAW_SUBMISSION" | jq -r '.metadata.name // .name // empty' 2>/dev/null || true)
    
    if [[ -z "$NEXT_RUN" ]]; then
        echo "✗ ERROR: Job submission failed - no jobrun name returned"
        echo ""
        echo "Raw output:"
        echo "$RAW_SUBMISSION"
        exit 1
    fi
    
    echo "✓ Volume Cloning triggered successfully"
    echo "  Jobrun instance: ${NEXT_RUN}"
else
    echo "→ Proceed to Volume Cloning not set - skipping Job 2"
    echo "  The LPAR will remain in ${STATUS} state"
    echo "  Ready for manual volume attachment and OS startup"
fi

echo ""
echo "========================================================================"
echo ""

# Mark job as successful
JOB_SUCCESS=1

sleep 1
exit 0
