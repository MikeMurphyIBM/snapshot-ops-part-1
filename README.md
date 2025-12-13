# IBMi PowerVS Backup & Restore Workflow

## Overview

This repository contains two standardized bash scripts that implement a complete backup and restore workflow for IBM Power Systems Virtual Servers (PowerVS) running IBMi.

### Workflow Summary

```
┌─────────────────────────────────────────────────────────────────┐
│                    BACKUP & RESTORE CYCLE                        │
└─────────────────────────────────────────────────────────────────┘

    ┌──────────────────────────────────┐
    │  JOB 1:                          │
    │  Provision → Snapshot → Restore  │    Complete workflow
    │                                  │ ──────────────────┐
    │  • Create empty LPAR             │                   │
    │  • Snapshot primary LPAR         │                   │
    │  • Clone volumes                 │                   │
    │  • Attach to secondary           │                   │
    │  • Boot secondary LPAR           │                   │
    └──────────────────────────────────┘                   │
                                                           ▼
                                                  ┌────────────────┐
                                                  │  JOB 2:        │
                                                  │  Cleanup       │
                                                  │                │
                                                  │  • Shutdown    │
                                                  │  • Detach vols │
                                                  │  • Delete vols │
                                                  │  • Delete snap │
                                                  └────────────────┘
```

---

## Script Files

### 1. `job1-provision-snapshot-restore.sh` - Complete Backup & Restore
**Combines:** Original `prod-v3.sh` + `prod-snap2.sh`

**Purpose:** Execute the complete backup and restore workflow in a single job.

**Phases:**
- **Phase A (Stages 1-4):** Provision empty secondary LPAR
- **Phase B (Stages 5-9):** Snapshot primary, clone, attach, and boot secondary

**Key Functions:**
- Authenticate to IBM Cloud and target PowerVS workspace
- Create empty LPAR with specified hardware configuration
- Wait for LPAR to reach SHUTOFF state
- Create snapshot of primary LPAR
- Clone all volumes (boot + data) from snapshot
- Attach cloned volumes to secondary LPAR
- Boot secondary LPAR in NORMAL mode
- Optionally chain to Job 2 for cleanup

**Environment Variables:**
- `IBMCLOUD_API_KEY` (required)
- `RUN_CLEANUP_JOB=Yes` (optional) - automatically trigger Job 2

**Cleanup on Failure:**
- Preserves snapshot (intentional for recovery)
- Deletes secondary LPAR if partially created
- Detaches all volumes from secondary LPAR
- Deletes cloned volumes
- Does NOT delete the primary LPAR or snapshot

---

### 2. `job2-cleanup-rollback.sh` - Environment Cleanup
**Original:** `latest3.sh`

**Purpose:** Return the environment to a clean state by removing volumes, snapshots, and optionally the LPAR.

**Key Functions:**
- Shutdown running LPAR
- Detach all volumes
- Delete all volumes
- Optionally delete snapshot
- Optionally delete LPAR

**Environment Variables:**
- `IBMCLOUD_API_KEY` (required)
- `DELETE_SNAPSHOT=Yes` (optional) - delete the snapshot
- `EXECUTE_LPAR_DELETE=Yes` (optional) - delete the LPAR itself

---

## Docker Deployment

### Dockerfiles Provided

- `Dockerfile.job1` - For Job 1 (provision-snapshot-restore)
- `Dockerfile.job2` - For Job 2 (cleanup)

Both Dockerfiles:
- Use Debian stable-slim base
- Install IBM Cloud CLI and required plugins
- Include `jq`, `curl`, and other dependencies
- Normalize line endings for cross-platform compatibility
- Set proper execution permissions

### Build Images

```bash
# Job 1: Provision, Snapshot, and Restore
docker build -f Dockerfile.job1 -t ibmi-backup-restore:latest .

# Job 2: Cleanup
docker build -f Dockerfile.job2 -t ibmi-cleanup:latest .
```

### Code Engine Deployment

```bash
# Create Code Engine jobs
ibmcloud ce job create \
    --name provision-snap-restore \
    --image your-registry/ibmi-backup-restore:latest \
    --env-from-secret ibmcloud-secrets

ibmcloud ce job create \
    --name prod-cleanup \
    --image your-registry/ibmi-cleanup:latest \
    --env-from-secret ibmcloud-secrets
```

### Run Full Automated Cycle

```bash
# Submit Job 1 with auto-cleanup enabled
ibmcloud ce jobrun submit \
    --job provision-snap-restore \
    --env RUN_CLEANUP_JOB=Yes \
    --env DELETE_SNAPSHOT=Yes \
    --env EXECUTE_LPAR_DELETE=No

# This will:
# 1. Provision secondary LPAR
# 2. Snapshot primary LPAR
# 3. Clone volumes
# 4. Attach to secondary and boot
# 5. Automatically trigger Job 2 cleanup
# 6. Shutdown, detach, and delete volumes
# 7. Delete snapshot
# 8. Keep LPAR for next cycle
```

---

## Quick Reference

### Environment Variables

| Variable | Job 1 | Job 2 | Required | Default |
|----------|-------|-------|----------|---------|
| `IBMCLOUD_API_KEY` | ✓ | ✓ | Yes | - |
| `RUN_CLEANUP_JOB` | ✓ | - | No | No |
| `DELETE_SNAPSHOT` | - | ✓ | No | No |
| `EXECUTE_LPAR_DELETE` | - | ✓ | No | No |

### Typical Execution Times

| Job | Phase/Stage | Duration |
|-----|-------------|----------|
| Job 1 | Phase A: LPAR creation | 5-10 minutes |
| Job 1 | Phase B: Snapshot creation | 10-20 minutes |
| Job 1 | Phase B: Volume cloning | 15-30 minutes |
| Job 1 | Phase B: LPAR boot | 5-15 minutes |
| Job 2 | Complete cleanup | 5-10 minutes |

**Total for full cycle:** ~40-85 minutes (varies by data size)

---

## Configuration Reference

### Job 1 Configuration

```bash
# IBM Cloud
IBMCLOUD_API_KEY="..."           # Set as environment variable
REGION="us-south"
RESOURCE_GROUP="Default"

# PowerVS Workspace
PVS_CRN="crn:v1:bluemix:public:power-iaas:dal10:..."
CLOUD_INSTANCE_ID="..."

# Network
SUBNET_ID="ca78b0d5-..."
PRIVATE_IP="192.168.0.69"
KEYPAIR_NAME="murphy-clone-key"

# LPARs
PRIMARY_LPAR="get-snapshot"           # Source LPAR
PRIMARY_INSTANCE_ID="c92f6904-..."
SECONDARY_LPAR="empty-ibmi-lpar"      # Target LPAR

# LPAR Specifications
MEMORY_GB=2
PROCESSORS=0.25
PROC_TYPE="shared"
SYS_TYPE="s1022"
IMAGE_ID="IBMI-EMPTY"

# Storage
STORAGE_TIER="tier3"

# Naming
CLONE_PREFIX="murph-$(date +"%Y%m%d%H%M")"
```

### Job 2 Configuration

```bash
# Target
LPAR_NAME="empty-ibmi-lpar"

# User Preferences
DELETE_SNAPSHOT="No"          # Yes to delete snapshot
EXECUTE_LPAR_DELETE="No"      # Yes to delete LPAR
```

---

## Migration from 3-Job to 2-Job Structure

If you're migrating from the previous 3-job structure:

### Old Structure
- **Job 1:** `prod-v3.sh` - Provision empty LPAR
- **Job 2:** `prod-snap2.sh` - Snapshot, clone, restore
- **Job 3:** `latest3.sh` - Cleanup

### New Structure
- **Job 1:** `job1-provision-snapshot-restore.sh` - Provision + Snapshot + Clone + Restore
- **Job 2:** `job2-cleanup-rollback.sh` - Cleanup

### Benefits of New Structure
- ✓ Simpler workflow (2 jobs instead of 3)
- ✓ Reduced Code Engine overhead
- ✓ Atomic backup operation (all or nothing)
- ✓ Easier to understand and maintain
- ✓ Better cleanup tracking

---

## Best Practices

1. **Test in Non-Production First** - Always test the full workflow in a development environment
2. **Monitor First Run** - Watch the logs to understand timing and catch issues early
3. **Keep Snapshots Initially** - Set `DELETE_SNAPSHOT=No` until confident in your backup strategy
4. **Verify Restorations** - After Job 1 completes, verify the restored LPAR is functional
5. **Save Logs** - `./job1-provision-snapshot-restore.sh 2>&1 | tee job1-$(date +%Y%m%d-%H%M%S).log`

---

## Summary

This standardized workflow provides:

✓ **Consistency:** Same variable names, formatting, error handling  
✓ **Visibility:** Comprehensive logging with timestamps and status indicators  
✓ **Reliability:** Robust error handling, cleanup, and rollback  
✓ **Maintainability:** Clear documentation and standardized structure  
✓ **Automation:** Support for chained execution via Code Engine  
✓ **Simplicity:** 2-job structure instead of 3

The scripts are production-ready and follow IBM Cloud and PowerVS best practices.
