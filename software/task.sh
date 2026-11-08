#!/usr/bin/env bash
# Target-local entry; transports supply target identity and deliver these resources.
set -u
set -o pipefail
task_root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$task_root/protocol.sh"
case "$TASK_OPERATION" in search|query|plan|apply|verify|remove|storage-plan|storage-check|backup-plan|backup-run|backup-restore) ;; *) task_stop invalid unknown-operation 2 ;; esac
task_request "${2:-}"
. "$task_root/storage.sh"
case "$TASK_OPERATION" in
    storage-plan) task_storage_plan; task_result success storage-planned 0 "$TASK_STORAGE_PLAN"; exit 0 ;;
    storage-check) task_storage_check; task_result success storage-verified 0 "$TASK_STORAGE_PLAN"; exit 0 ;;
esac
. "$task_root/native.sh"
. "$task_root/selection.sh"
. "$task_root/backup.sh"
case "$TASK_OPERATION" in
    backup-plan) task_backup_plan; task_result success backup-planned 0 "$TASK_BACKUP_PLAN" ;;
    backup-run) task_backup_run "$("$task_jq" -c '.backupPlan//empty' <<< "$TASK_REQUEST_JSON")"; task_result success backed-up 0 "$TASK_BACKUP_RECEIPT" "$TASK_EFFECTS" ;;
    backup-restore) task_backup_restore; task_result success restored 0 "$TASK_BACKUP_RESTORED" "$TASK_EFFECTS" ;;
    search) task_native_search ;;
    query|verify)
        task_observe
        if [ "$TASK_OPERATION" = verify ] && [ "$("$task_jq" -r .satisfies <<< "$TASK_OBSERVED")" != true ]; then task_stop failed functional-verification-failed 11 "$TASK_OBSERVED"; fi
        task_result success observed 0 "$TASK_OBSERVED" ;;
    plan)
        task_make_plan
        task_result success planned 0 "$TASK_PLAN" ;;
    apply) task_apply_plan ;;
    remove)
        [ "$("$task_jq" -r '.intent//""' <<< "$TASK_REQUEST_JSON")" = remove ] || task_stop blocked removal-needs-owner-plan 0
        task_apply_plan ;;
esac
