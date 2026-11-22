# Load only the mechanics required by this operation. No target commands here.
task_load() {
    local module
    for module in "$@"; do
        . "$task_root/$module.sh" || task_stop failed missing-rule-module 11
    done
}
case "$TASK_OPERATION" in
    search) task_load native ;;
    storage-*) task_load storage ;;
    backup-*) task_load storage backup ;;
    query|verify)
        task_load selection
        case "$("$task_jq" -r '.method//""' <<< "$TASK_REQUEST_JSON")" in
            native-package) task_load native ;;
            artifact|release) task_load artifact ;;
        esac ;;
    plan|apply|remove) task_load storage native selection backup container artifact release ;;
esac
