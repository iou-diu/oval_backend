#!/usr/bin/env bash
# update.sh - routine code update of a git-based deployment. Run as root from
# the project folder:
#
#   bash update.sh
#
# Pulls (fast-forward only), installs requirements only when requirements.txt
# changed, generates and applies migrations, collects static files, restarts
# only this project's supervisor program and checks that it answers.
# Configuration changes (.env.production) need deploy.sh instead.

# Reuse the parser and helpers from deploy.sh (sourcing it runs nothing).
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/deploy.sh"

update_main() {
    set -Eeuo pipefail
    umask 022
    trap 'on_err $? $LINENO "$BASH_COMMAND"' ERR
    TOTAL_STEPS=6

    step "Checking"
    check_root_linux
    load_config "$CONFIG_FILE"
    resolve_config
    check_run_user
    [[ $(readlink -f "$PROJECT_FOLDER") == "$SCRIPT_DIR" ]] ||
        die "update.sh must be run from project_folder ($PROJECT_FOLDER), not from $SCRIPT_DIR."
    [[ -d $PROJECT_FOLDER/.git ]] || die "$PROJECT_FOLDER is not a git checkout; update it with deploy.sh."
    [[ -x $VENV/bin/python && -f $APP_ENV ]] || die "No previous deploy found (missing $VENV or $APP_ENV); run deploy.sh first."
    [[ $(supervisorctl status "$PROJECT_NAME" 2>&1) != *"no such process"* ]] ||
        die "supervisor has no program '$PROJECT_NAME'; run deploy.sh first."
    if [[ $CONFIG_FILE -nt $APP_ENV ]]; then
        warn ".env.production changed after the last deploy; run deploy.sh to apply it (update.sh does not)."
    fi
    take_lock
    add_safe_directory
    ok "$PROJECT_NAME in $PROJECT_FOLDER (user $RUN_USER)"

    step "Pulling code"
    local before after
    before=$(git -C "$PROJECT_FOLDER" rev-parse HEAD)
    git -C "$PROJECT_FOLDER" pull --ff-only ||
        die "git pull --ff-only failed." \
            "If the server has local changes or the branch diverged, look at: git -C $PROJECT_FOLDER status"
    after=$(git -C "$PROJECT_FOLDER" rev-parse HEAD)
    if [[ $before == "$after" ]]; then
        ok "already up to date ($(git -C "$PROJECT_FOLDER" rev-parse --short HEAD))"
    else
        git -C "$PROJECT_FOLDER" log --oneline "$before..$after" | sed 's/^/      /'
        ok "updated to $(git -C "$PROJECT_FOLDER" rev-parse --short HEAD)"
    fi
    # Files pulled as root would otherwise stay root-owned.
    chown -R "$RUN_USER" "$PROJECT_FOLDER"

    step "Requirements"
    install_requirements

    step "Migrations and static files"
    run_migrations

    step "Restarting [$PROJECT_NAME]"
    local out
    out=$(supervisorctl restart "$PROJECT_NAME" 2>&1 || true)
    check_supervisor_result "$out"
    ok "restarted $PROJECT_NAME"

    step "Health check"
    health_check

    printf '\n%sUpdated %s%s\n' "$C_BOLD$C_GREEN" "$PROJECT_NAME" "$C_RESET"
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    update_main "$@"
fi
