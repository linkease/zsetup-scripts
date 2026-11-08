#!/usr/bin/env bash
# Target-local entry; transports supply target identity and deliver these resources.
set -u
set -o pipefail
task_root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$task_root/protocol.sh"
case "$TASK_OPERATION" in query|plan|apply|verify|remove|storage-plan|storage-check) ;; *) task_stop invalid unknown-operation 2 ;; esac
task_request "${2:-}"
. "$task_root/storage.sh"
case "$TASK_OPERATION" in
    storage-plan) task_storage_plan; task_result success storage-planned 0 "$TASK_STORAGE_PLAN"; exit 0 ;;
    storage-check) task_storage_check; task_result success storage-verified 0 "$TASK_STORAGE_PLAN"; exit 0 ;;
esac
case "$TASK_SOFTWARE" in bash|jq) ;; *) task_stop needs-ai no-installation-rule 0 ;; esac
task_executable=$(type -P "$TASK_SOFTWARE" || true)
if [ -n "$task_executable" ]; then
    task_version=$("$task_executable" --version 2>/dev/null | head -n 1)
    task_details=$("$task_jq" -cn --arg path "$task_executable" --arg version "$task_version" '{installed:true,executable:$path,observedVersion:$version,functionalValidation:"not-run",manager:"existing"}')
    case "$TASK_OPERATION" in
        query) task_result success observed 0 "$task_details"; exit 0 ;;
        plan) task_result success reusable 0 "$task_details"; exit 0 ;;
    esac
fi
task_stop needs-ai no-installation-rule 0
