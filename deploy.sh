#!/usr/bin/env bash
# deploy.sh - first deploy and any configuration change, on Ubuntu/Debian.
#
#   bash deploy.sh            (as root, next to .env.production)
#
# Safe to run again: files that are already correct are left alone, nothing
# that belongs to other projects on the server is touched. Routine code
# updates use update.sh instead.
#
# The file can be sourced (functions only); main runs only when executed.

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
CONFIG_FILE=${CONFIG_FILE:-$SCRIPT_DIR/.env.production}

# Project specifics
WSGI_MODULE=oval_backend.wsgi:application
HEALTH_PATH=/account/login/          # must answer 200 without login
SUPPORTED_PYTHONS="3.10 3.11 3.12"   # pinned wheels (psycopg2-binary 2.9.9, pillow 10.4.0) stop at 3.12

# Paths outside the project (overridable for tests)
NGINX_DIR=${NGINX_DIR:-/etc/nginx}
SUPERVISOR_DIR=${SUPERVISOR_DIR:-/etc/supervisor}
LE_LIVE_DIR=${LE_LIVE_DIR:-/etc/letsencrypt/live}
LE_DIR=${LE_DIR:-/etc/letsencrypt}

# Lowercase keys of .env.production that configure the deployment. Every
# other key is passed through unchanged to the app's .env.
DEPLOY_KEYS=" project_folder project_name logs run_user database_name database_user
  database_password database_host database_port domain nginx_port frontend_urls
  gunicorn_workers max_upload_size admin_email admin_password redis_host redis_port
  git_repo git_branch "

declare -A CFG=()     # deploy keys
declare -A APP=()     # pass-through keys
APP_KEYS=()           # pass-through keys, in file order
OUTSIDE_CHANGES=()    # permission changes made outside the project folder

STEP=0
TOTAL_STEPS=12
STEP_NAME="start"

# ----------------------------------------------------------------------------
# Output
# ----------------------------------------------------------------------------
if [[ -t 1 ]]; then
    C_BOLD=$'\e[1m' C_RED=$'\e[31m' C_GREEN=$'\e[32m' C_YELLOW=$'\e[33m' C_RESET=$'\e[0m'
else
    C_BOLD='' C_RED='' C_GREEN='' C_YELLOW='' C_RESET=''
fi

step() {
    STEP=$((STEP + 1))
    STEP_NAME=$1
    printf '\n%s[%d/%d] %s%s\n' "$C_BOLD" "$STEP" "$TOTAL_STEPS" "$1" "$C_RESET"
}
info() { printf '      %s\n' "$*"; }
ok()   { printf '      %sok%s  %s\n' "$C_GREEN" "$C_RESET" "$*"; }
warn() { printf '      %sWARNING%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }

# die "message" ["hint line" ...]
die() {
    printf '\n%sERROR%s (step %d, %s): %s\n' "$C_RED" "$C_RESET" "$STEP" "$STEP_NAME" "$1" >&2
    shift
    local line
    for line in "$@"; do printf '      %s\n' "$line" >&2; done
    exit 1
}

on_err() {
    local rc=$1 line=$2 cmd=$3
    ((BASH_SUBSHELL == 0)) || return 0   # the parent shell reports it
    printf '\n%sERROR%s (step %d, %s): command failed with exit code %d at line %d:\n      %s\n' \
        "$C_RED" "$C_RESET" "$STEP" "$STEP_NAME" "$rc" "$line" "$cmd" >&2
    printf '      Nothing after this point was changed. Fix the cause and run the script again.\n' >&2
}

# ----------------------------------------------------------------------------
# Small helpers
# ----------------------------------------------------------------------------
trim() {
    local s=$1
    s=${s#"${s%%[![:space:]]*}"}
    s=${s%"${s##*[![:space:]]}"}
    printf '%s' "$s"
}

join_by() {
    local sep=$1 out='' item
    shift
    for item in "$@"; do out+=${out:+$sep}$item; done
    printf '%s' "$out"
}

# Percent-encode every byte except unreserved URL characters.
urlencode() {
    local LC_ALL=C s=$1 out='' c i
    for ((i = 0; i < ${#s}; i++)); do
        c=${s:i:1}
        case $c in
            [a-zA-Z0-9._~-]) out+=$c ;;
            *) printf -v c '%%%02X' "'$c"; out+=${c: -3} ;;
        esac
    done
    printf '%s' "$out"
}

# Write a value so python-decouple reads it back unchanged: it strips
# surrounding whitespace and one pair of matching quotes, nothing else.
env_quote() {
    local v=$1 first last
    first=${v:0:1}
    last=${v: -1}
    if [[ $v =~ ^[[:space:]] || $v =~ [[:space:]]$ ]] ||
        { ((${#v} >= 2)) && [[ $first == "$last" && ($first == '"' || $first == "'") ]]; }; then
        printf "'%s'" "$v"
    else
        printf '%s' "$v"
    fi
}

is_deploy_key() { [[ $DEPLOY_KEYS == *[[:space:]]"$1"[[:space:]]* ]]; }

# Run a command as the app user with a clean environment (python-decouple
# prefers environment variables over .env, so nothing may leak in from root).
run_as() {
    (cd "$PROJECT_FOLDER" && runuser -u "$RUN_USER" -- env -i HOME="$RUN_HOME" USER="$RUN_USER" LANG=C.UTF-8 \
        PATH="$VENV/bin:/usr/local/bin:/usr/bin:/bin" "$@")
}

manage() { run_as "$VENV/bin/python" manage.py "$@"; }

# write_if_changed PATH MODE OWNER:GROUP < content
# Returns 0 when the file was written, 1 when it was already identical.
write_if_changed() {
    local path=$1 mode=$2 owner=$3 tmp
    tmp=$(mktemp "$(dirname "$path")/.${path##*/}.XXXXXX")
    cat > "$tmp"
    if [[ -f $path ]] && cmp -s "$tmp" "$path" &&
        [[ $(stat -c '%a %U:%G' "$path") == "$mode $owner" ]]; then
        rm -f "$tmp"
        return 1
    fi
    chmod "$mode" "$tmp"
    chown "$owner" "$tmp"
    mv -f "$tmp" "$path"
    return 0
}

# Grep that never waits for stdin: /dev/null is always one of the files.
grep_files() {
    local pattern=$1
    shift
    grep -ilE "$pattern" "$@" /dev/null 2>/dev/null || true
}

# ----------------------------------------------------------------------------
# Configuration
# ----------------------------------------------------------------------------
# Line-by-line parser; the file is never sourced, so values may contain any
# character. Strips \r, a BOM, surrounding whitespace and one pair of quotes.
load_config() {
    local file=$1 line key val n=0
    [[ -f $file ]] || die "Config file not found: $file" \
        "Create it from .env.production.example: cp .env.production.example .env.production"
    CFG=() APP=() APP_KEYS=()
    while IFS= read -r line || [[ -n $line ]]; do
        n=$((n + 1))
        line=${line%$'\r'}
        ((n == 1)) && line=${line#$'\xef\xbb\xbf'}
        [[ $line =~ ^[[:space:]]*(#|$) ]] && continue
        if [[ $line =~ ^[[:space:]]*(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*=(.*)$ ]]; then
            key=${BASH_REMATCH[2]}
            val=$(trim "${BASH_REMATCH[3]}")
        else
            die "$file line $n is not KEY=value." "Comment lines must start with #."
        fi
        if ((${#val} >= 2)) && [[ ${val:0:1} == "${val: -1}" && (${val:0:1} == '"' || ${val:0:1} == "'") ]]; then
            val=${val:1:${#val}-2}
        fi
        if is_deploy_key "$key"; then
            CFG[$key]=$val
        else
            [[ -v APP[$key] ]] || APP_KEYS+=("$key")
            APP[$key]=$val
        fi
    done < "$file"
}

cfg() { printf '%s' "${CFG[$1]:-${2:-}}"; }

require_cfg() {
    [[ -n ${CFG[$1]:-} ]] || die "'$1' is empty or missing in $CONFIG_FILE." "See .env.production.example for what it means."
}

# Validates the config and derives every path/value the steps use.
resolve_config() {
    local k raw part
    for k in project_folder project_name run_user database_name database_user database_password; do
        require_cfg "$k"
    done

    PROJECT_NAME=$(cfg project_name)
    [[ $PROJECT_NAME =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] ||
        die "project_name may contain only letters, digits, '.', '_' and '-' (got '$PROJECT_NAME')."

    PROJECT_FOLDER=$(cfg project_folder)
    PROJECT_FOLDER=${PROJECT_FOLDER%/}
    [[ $PROJECT_FOLDER =~ ^/[A-Za-z0-9._/-]+$ && $PROJECT_FOLDER != *..* ]] ||
        die "project_folder must be an absolute path made of letters, digits, '.', '_', '-' and '/' (got '$PROJECT_FOLDER')."
    case $PROJECT_FOLDER in
        /|/home|/root|/srv|/opt|/var|/var/www|/usr|/etc|/tmp) die "project_folder '$PROJECT_FOLDER' is a shared system folder; use a folder of its own, e.g. /home/<user>/$PROJECT_NAME." ;;
    esac

    LOG_DIR=$(cfg logs "$PROJECT_FOLDER/logs")
    LOG_DIR=${LOG_DIR%/}
    [[ $LOG_DIR =~ ^/[A-Za-z0-9._/-]+$ ]] || die "logs must be an absolute path (got '$LOG_DIR')."

    RUN_USER=$(cfg run_user)
    [[ $RUN_USER != root ]] || die "run_user must not be root." \
        "Create a dedicated user:  adduser --disabled-password --gecos \"\" $PROJECT_NAME"

    DB_NAME=$(cfg database_name)
    DB_USER=$(cfg database_user)
    DB_PASSWORD=$(cfg database_password)
    DB_HOST=$(cfg database_host localhost)
    DB_PORT=$(cfg database_port 5432)
    [[ $DB_NAME =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || die "database_name may contain only letters, digits and '_' (got '$DB_NAME')."
    [[ $DB_USER =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || die "database_user may contain only letters, digits and '_' (got '$DB_USER')."
    [[ $DB_HOST =~ ^[A-Za-z0-9.:-]+$ ]] || die "database_host looks invalid (got '$DB_HOST')."
    [[ $DB_PORT =~ ^[0-9]+$ ]] || die "database_port must be a number (got '$DB_PORT')."
    case $DB_HOST in localhost|127.0.0.1|::1) DB_LOCAL=1 ;; *) DB_LOCAL=0 ;; esac

    DOMAINS=()
    IFS=, read -ra raw <<< "$(cfg domain)"
    for part in ${raw[@]+"${raw[@]}"}; do
        part=$(trim "$part")
        part=${part,,}
        [[ -z $part ]] && continue
        [[ $part =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$ ]] ||
            die "domain '$part' is not a plain host name (no scheme, port, path or wildcard)."
        DOMAINS+=("$part")
    done

    NGINX_PORT=$(cfg nginx_port 80)
    [[ $NGINX_PORT =~ ^[0-9]+$ ]] && ((NGINX_PORT >= 1 && NGINX_PORT <= 65535)) ||
        die "nginx_port must be a port number (got '$NGINX_PORT')."
    if ((${#DOMAINS[@]} == 0 && NGINX_PORT == 80)); then
        die "No domain on port 80 would take over every request to this server that no other site claims." \
            "Set domain=your.domain (or the server's public IP), or pick a free nginx_port such as 8081."
    fi

    FRONTEND_URLS=()
    IFS=, read -ra raw <<< "$(cfg frontend_urls)"
    for part in ${raw[@]+"${raw[@]}"}; do
        part=$(trim "$part")
        part=${part%/}
        [[ -z $part ]] && continue
        [[ $part =~ ^https?://[A-Za-z0-9.-]+(:[0-9]+)?$ ]] ||
            die "frontend_urls entry '$part' must look like https://shop.example.com (scheme + host, no path)."
        FRONTEND_URLS+=("$part")
    done

    GUNICORN_WORKERS=$(cfg gunicorn_workers 3)
    [[ $GUNICORN_WORKERS =~ ^[1-9][0-9]*$ ]] || die "gunicorn_workers must be a positive number (got '$GUNICORN_WORKERS')."

    MAX_UPLOAD_SIZE=$(cfg max_upload_size 20M)
    [[ $MAX_UPLOAD_SIZE =~ ^[0-9]+[kKmMgG]?$ ]] || die "max_upload_size must look like 20M (got '$MAX_UPLOAD_SIZE')."

    ADMIN_EMAIL=$(cfg admin_email)
    ADMIN_PASSWORD=$(cfg admin_password)
    if [[ -n $ADMIN_EMAIL && -z $ADMIN_PASSWORD ]] || [[ -z $ADMIN_EMAIL && -n $ADMIN_PASSWORD ]]; then
        die "Set both admin_email and admin_password, or neither."
    fi

    REDIS_HOST=$(cfg redis_host)
    REDIS_PORT=$(cfg redis_port 6379)
    [[ -z $REDIS_HOST || $REDIS_HOST =~ ^[A-Za-z0-9.:-]+$ ]] || die "redis_host looks invalid (got '$REDIS_HOST')."
    [[ $REDIS_PORT =~ ^[0-9]+$ ]] || die "redis_port must be a number (got '$REDIS_PORT')."

    GIT_REPO=$(cfg git_repo)
    GIT_BRANCH=$(cfg git_branch main)

    VENV=$PROJECT_FOLDER/venv
    RUN_DIR=$PROJECT_FOLDER/run
    SOCKET=$RUN_DIR/gunicorn.sock
    STATIC_DIR=$PROJECT_FOLDER/staticfiles
    MEDIA_DIR=$PROJECT_FOLDER/media
    CACHE_DIR=$PROJECT_FOLDER/cache
    APP_ENV=$PROJECT_FOLDER/.env

    NGINX_SITE=$NGINX_DIR/sites-available/$PROJECT_NAME
    NGINX_LINK=$NGINX_DIR/sites-enabled/$PROJECT_NAME
    SUPERVISOR_CONF=$SUPERVISOR_DIR/conf.d/$PROJECT_NAME.conf
    MARKER="# deploy.sh: $PROJECT_FOLDER"

    HTTPS_ENABLED=0
    if ((${#DOMAINS[@]})) && [[ -f $LE_LIVE_DIR/${DOMAINS[0]}/fullchain.pem && -f $LE_LIVE_DIR/${DOMAINS[0]}/privkey.pem ]]; then
        HTTPS_ENABLED=1
    fi
    CERT_DIR=$LE_LIVE_DIR/${DOMAINS[0]:-none}

    # Without a domain, Django must accept the server's own addresses.
    if ((${#DOMAINS[@]})); then
        HOSTS=("${DOMAINS[@]}")
    else
        HOSTS=()
        read -ra raw <<< "${SERVER_IPS-$(hostname -I 2>/dev/null || true)}"
        for part in ${raw[@]+"${raw[@]}"}; do
            [[ $part == *:* ]] || HOSTS+=("$part")   # IPv4 only; IPv6 would need [brackets]
        done
        HOSTS+=(localhost 127.0.0.1)
    fi
    HEALTH_HOST=${HOSTS[0]}
}

# Origins Django must trust for CSRF: the site itself plus the frontends.
compute_origins() {
    local h port_suffix=''
    ((NGINX_PORT != 80)) && port_suffix=":$NGINX_PORT"
    CSRF_ORIGINS=()
    for h in "${HOSTS[@]}"; do
        if ((HTTPS_ENABLED)); then
            CSRF_ORIGINS+=("https://$h")
        else
            CSRF_ORIGINS+=("http://$h$port_suffix")
        fi
    done
    CSRF_ORIGINS+=(${FRONTEND_URLS[@]+"${FRONTEND_URLS[@]}"})
}

# SECRET_KEY: .env.production wins, then the one already in the app .env,
# otherwise a new random one. Keeping it stable keeps sessions valid.
resolve_secret_key() {
    local line
    SECRET_KEY_VALUE=${APP[SECRET_KEY]:-}
    if [[ -z $SECRET_KEY_VALUE && -f $APP_ENV ]]; then
        while IFS= read -r line || [[ -n $line ]]; do
            if [[ $line =~ ^[[:space:]]*SECRET_KEY[[:space:]]*=(.*)$ ]]; then
                SECRET_KEY_VALUE=$(trim "${BASH_REMATCH[1]}")
                if ((${#SECRET_KEY_VALUE} >= 2)) && [[ ${SECRET_KEY_VALUE:0:1} == "${SECRET_KEY_VALUE: -1}" && (${SECRET_KEY_VALUE:0:1} == '"' || ${SECRET_KEY_VALUE:0:1} == "'") ]]; then
                    SECRET_KEY_VALUE=${SECRET_KEY_VALUE:1:${#SECRET_KEY_VALUE}-2}
                fi
            fi
        done < "$APP_ENV"
    fi
    if [[ -z $SECRET_KEY_VALUE ]]; then
        SECRET_KEY_VALUE=$(head -c 64 /dev/urandom | base64 -w0 | tr -d '/+=')
        SECRET_KEY_NEW=1
    fi
}

# ----------------------------------------------------------------------------
# Renderers (pure: they only print, so tests can call them)
# ----------------------------------------------------------------------------
render_app_env() {
    local -A out=()
    local order=() k secure=False
    ((HTTPS_ENABLED)) && secure=True
    _put() { [[ -v out[$1] ]] || order+=("$1"); out[$1]=$2; }

    _put DEBUG False
    _put SECRET_KEY "$SECRET_KEY_VALUE"
    _put ALLOWED_HOSTS "$(join_by , "${HOSTS[@]}")"
    _put CSRF_TRUSTED_ORIGINS "$(join_by , "${CSRF_ORIGINS[@]}")"
    _put CORS_ALLOWED_ORIGINS "$(join_by , ${FRONTEND_URLS[@]+"${FRONTEND_URLS[@]}"})"
    _put DATABASE_URL "postgres://$(urlencode "$DB_USER"):$(urlencode "$DB_PASSWORD")@$DB_HOST:$DB_PORT/$(urlencode "$DB_NAME")"
    _put REDIS_HOST "$REDIS_HOST"
    _put REDIS_PORT "$REDIS_PORT"
    _put CACHE_DIR "$CACHE_DIR"
    _put CACHE_KEY_PREFIX "$PROJECT_NAME"
    _put STATIC_ROOT "$STATIC_DIR"
    _put MEDIA_ROOT "$MEDIA_DIR"
    _put BEHIND_PROXY True
    _put SESSION_COOKIE_SECURE "$secure"
    _put CSRF_COOKIE_SECURE "$secure"
    for k in ${APP_KEYS[@]+"${APP_KEYS[@]}"}; do
        _put "$k" "${APP[$k]}"
    done
    unset -f _put

    printf '# Generated by deploy.sh from .env.production - edit that file and re-run deploy.sh.\n'
    for k in "${order[@]}"; do
        printf '%s=%s\n' "$k" "$(env_quote "${out[$k]}")"
    done
}

render_supervisor_conf() {
    cat <<EOF
$MARKER
; Managed by deploy.sh - edit .env.production and re-run deploy.sh instead.
[program:$PROJECT_NAME]
command=$VENV/bin/gunicorn $WSGI_MODULE --workers $GUNICORN_WORKERS --bind unix:$SOCKET --umask 0002 --timeout 120 --graceful-timeout 30 --access-logfile - --error-logfile -
directory=$PROJECT_FOLDER
user=$RUN_USER
environment=HOME="$RUN_HOME",USER="$RUN_USER",LANG="C.UTF-8",PATH="$VENV/bin:/usr/local/bin:/usr/bin:/bin"
autostart=true
autorestart=true
startsecs=5
stopasgroup=true
killasgroup=true
stopwaitsecs=35
redirect_stderr=true
stdout_logfile=$LOG_DIR/gunicorn.log
stdout_logfile_maxbytes=20MB
stdout_logfile_backups=5
EOF
}

_nginx_app_locations() {
    cat <<EOF
    client_max_body_size $MAX_UPLOAD_SIZE;

    access_log /var/log/nginx/$PROJECT_NAME.access.log;
    error_log /var/log/nginx/$PROJECT_NAME.error.log;

    location /static/ {
        alias $STATIC_DIR/;
        expires 30d;
        access_log off;
    }

    location /media/ {
        alias $MEDIA_DIR/;
        add_header X-Content-Type-Options nosniff;
    }

    location / {
        proxy_pass http://unix:$SOCKET;
        proxy_set_header Host \$http_host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_redirect off;
        proxy_read_timeout 120s;
    }
EOF
}

render_nginx_conf() {
    local names listen6='' listen6_ssl=''
    names=$(join_by ' ' ${DOMAINS[@]+"${DOMAINS[@]}"})
    names=${names:-_}
    if ((${IPV6:-0})); then
        listen6=$'\n'"    listen [::]:$NGINX_PORT;"
        listen6_ssl=$'\n'"    listen [::]:443 ssl;"
    fi

    printf '%s\n# Managed by deploy.sh - edit .env.production and re-run deploy.sh instead.\n' "$MARKER"
    if ((HTTPS_ENABLED)); then
        cat <<EOF

server {
    listen $NGINX_PORT;$listen6
    server_name $names;

    location / {
        return 301 https://\$host\$request_uri;
    }
}

server {
    listen 443 ssl;$listen6_ssl
    server_name $names;

    ssl_certificate $CERT_DIR/fullchain.pem;
    ssl_certificate_key $CERT_DIR/privkey.pem;
EOF
        [[ -f $LE_DIR/options-ssl-nginx.conf ]] && printf '    include %s/options-ssl-nginx.conf;\n' "$LE_DIR"
        [[ -f $LE_DIR/ssl-dhparams.pem ]] && printf '    ssl_dhparam %s/ssl-dhparams.pem;\n' "$LE_DIR"
        printf '\n'
        _nginx_app_locations
        printf '}\n'
    else
        cat <<EOF

server {
    listen $NGINX_PORT;$listen6
    server_name $names;

EOF
        _nginx_app_locations
        printf '}\n'
    fi
}

# ----------------------------------------------------------------------------
# Steps
# ----------------------------------------------------------------------------
find_python() {
    local c v
    for c in python3 python3.12 python3.11 python3.10; do
        command -v "$c" >/dev/null 2>&1 || continue
        v=$("$c" -c 'import sys; print("%d.%d" % sys.version_info[:2])' 2>/dev/null) || continue
        if [[ " $SUPPORTED_PYTHONS " == *" $v "* ]]; then
            PY=$(command -v "$c")
            PY_VERSION=$v
            PY_VENV_PKG=$([[ $c == python3 ]] && echo python3-venv || echo "$c-venv")
            return 0
        fi
    done
    return 1
}

check_root_linux() {
    [[ $(uname -s) == Linux ]] || die "This script runs on Linux (Ubuntu/Debian) only."
    ((EUID == 0)) || die "Run as root: sudo bash $0"
    command -v apt-get >/dev/null || die "apt-get not found; only Ubuntu/Debian are supported."
    command -v runuser >/dev/null || die "runuser not found (package util-linux)."
}

check_run_user() {
    id -u "$RUN_USER" >/dev/null 2>&1 || die "User '$RUN_USER' does not exist. The app must run as its own non-root user." \
        "Create it:  adduser --disabled-password --gecos \"\" $RUN_USER" "Then run this script again."
    (($(id -u "$RUN_USER") != 0)) || die "run_user '$RUN_USER' has uid 0; use a normal user." \
        "Create one:  adduser --disabled-password --gecos \"\" $PROJECT_NAME"
    RUN_HOME=$(getent passwd "$RUN_USER" | cut -d: -f6)
    RUN_GROUP=$(id -gn "$RUN_USER")
}

take_lock() {
    mkdir -p /run/lock
    exec 9> "/run/lock/deploy-$PROJECT_NAME.lock"
    flock -n 9 || die "Another deploy.sh/update.sh for '$PROJECT_NAME' is running."
}

step_check_server() {
    step "Checking the server"
    check_root_linux

    local perms k
    perms=$(stat -c '%a' "$CONFIG_FILE" 2>/dev/null || true)
    load_config "$CONFIG_FILE"
    if [[ -n $perms && $perms != 600 ]]; then
        chmod 600 "$CONFIG_FILE"
        warn "$CONFIG_FILE was mode $perms; set it to 600 (it holds passwords)."
    fi
    resolve_config
    ok "config: $CONFIG_FILE"

    check_run_user
    ok "app user: $RUN_USER (home $RUN_HOME)"

    find_python || die "No supported Python found (need one of: $SUPPORTED_PYTHONS)." \
        "The pinned requirements (psycopg2-binary 2.9.9, pillow 10.4.0) have no wheels for 3.13 yet." \
        "Ubuntu 22.04 ships 3.10, 24.04 ships 3.12, Debian 12 ships 3.11."
    ok "python: $PY ($PY_VERSION)"

    IPV6=0
    [[ -e /proc/net/if_inet6 ]] && IPV6=1

    for k in ${APP_KEYS[@]+"${APP_KEYS[@]}"}; do
        if [[ $k =~ [a-z] && ! $k =~ [A-Z] ]]; then
            info "lowercase key '$k' is not a deploy key; passing it to the app .env"
        fi
    done

    take_lock
}

# Everything that could collide with other projects is checked before any change.
step_preflight() {
    step "Checking for conflicts with other projects"
    local files=() f d hits conflict listeners

    if [[ -d $NGINX_DIR ]]; then
        grep -qs 'sites-enabled' "$NGINX_DIR/nginx.conf" ||
            die "$NGINX_DIR/nginx.conf does not include sites-enabled/; this script only manages sites there."
        for f in "$NGINX_DIR"/sites-enabled/* "$NGINX_DIR"/conf.d/*.conf; do
            [[ -e $f ]] || continue
            [[ $f == "$NGINX_LINK" ]] && continue
            [[ $(readlink -f "$f") == "$NGINX_SITE" ]] && continue
            files+=("$f")
        done
        for d in ${DOMAINS[@]+"${DOMAINS[@]}"}; do
            hits=$(grep_files "^[[:space:]]*server_name[^#;]*[[:space:]]${d//./\\.}([[:space:];]|$)" ${files[@]+"${files[@]}"})
            [[ -z $hits ]] || die "Domain '$d' is already served by another nginx site:" $hits \
                "Pick another domain or remove it from that site first."
        done
        if ((${#DOMAINS[@]} == 0)); then
            hits=$(grep_files "^[[:space:]]*listen[[:space:]]+([^[:space:];]*:)?${NGINX_PORT}([[:space:];]|$)" ${files[@]+"${files[@]}"})
            [[ -z $hits ]] || die "Port $NGINX_PORT is already used by another nginx site, and there is no domain to tell them apart:" $hits \
                "Set domain= or choose another nginx_port."
        fi
        for f in "$NGINX_SITE" "$NGINX_LINK"; do
            [[ -e $f || -L $f ]] || continue
            [[ $f == "$NGINX_LINK" && $(readlink -f "$f") != "$NGINX_SITE" ]] &&
                die "$f exists but does not point to $NGINX_SITE; it belongs to something else."
            grep -qxF "$MARKER" "$f" ||
                die "$f exists but was not written by deploy.sh for $PROJECT_FOLDER." \
                    "Another project probably uses the name '$PROJECT_NAME'. Choose another project_name."
        done
    fi

    if command -v ss >/dev/null; then
        listeners=$(ss -Hltnp "( sport = :$NGINX_PORT )" 2>/dev/null || true)
        if [[ -n $listeners && $listeners != *'"nginx"'* ]]; then
            die "Port $NGINX_PORT is in use by a program other than nginx:" "$listeners" "Choose another nginx_port."
        fi
    fi

    if [[ -d $SUPERVISOR_DIR ]]; then
        files=()
        for f in "$SUPERVISOR_DIR"/supervisord.conf "$SUPERVISOR_DIR"/conf.d/*; do
            [[ -f $f && $f != "$SUPERVISOR_CONF" ]] && files+=("$f")
        done
        hits=$(grep_files "^[[:space:]]*\[program:${PROJECT_NAME//./\\.}\]" ${files[@]+"${files[@]}"})
        [[ -z $hits ]] || die "A supervisor program named '$PROJECT_NAME' already exists in:" $hits "Choose another project_name."
        if [[ -f $SUPERVISOR_CONF ]] && ! grep -qxF "$MARKER" "$SUPERVISOR_CONF"; then
            die "$SUPERVISOR_CONF exists but was not written by deploy.sh for $PROJECT_FOLDER." \
                "Another project probably uses the name '$PROJECT_NAME'. Choose another project_name."
        fi
    fi

    if [[ -n $REDIS_HOST ]]; then
        timeout 3 bash -c 'exec 3<>"/dev/tcp/$1/$2"' _ "$REDIS_HOST" "$REDIS_PORT" 2>/dev/null ||
            die "redis_host is set but nothing answers on $REDIS_HOST:$REDIS_PORT." \
                "Start Redis (e.g. apt install redis-server), fix redis_host/redis_port," \
                "or leave redis_host empty to use a file cache in $CACHE_DIR."
        ok "redis reachable at $REDIS_HOST:$REDIS_PORT"
    else
        ok "no redis_host: using a file cache in $CACHE_DIR"
    fi
    ok "no conflicting nginx site, port or supervisor program"
}

pg_native_installed() { compgen -G '/usr/lib/postgresql/*/bin/postgres' >/dev/null && id -u postgres >/dev/null 2>&1; }
port_open() { timeout 3 bash -c 'exec 3<>"/dev/tcp/$1/$2"' _ "$1" "$2" 2>/dev/null; }

step_packages() {
    step "Installing missing packages"
    local missing=()
    command -v nginx >/dev/null || missing+=(nginx)
    command -v supervisorctl >/dev/null || missing+=(supervisor)
    command -v curl >/dev/null || missing+=(curl)
    command -v git >/dev/null || missing+=(git)
    command -v rsync >/dev/null || missing+=(rsync)
    "$PY" -c 'import ensurepip, venv' 2>/dev/null || missing+=("$PY_VENV_PKG")
    if ((DB_LOCAL)) && ! pg_native_installed && ! port_open 127.0.0.1 "$DB_PORT"; then
        missing+=(postgresql)
    fi
    command -v psql >/dev/null || [[ " ${missing[*]} " == *" postgresql "* ]] || missing+=(postgresql-client)

    if ((${#missing[@]})); then
        info "installing: ${missing[*]}"
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -q
        apt-get install -y -q --no-upgrade "${missing[@]}"
        ok "installed: ${missing[*]}"
    else
        ok "all required packages already installed"
    fi

    # Starting nginx/supervisor would also start other projects, so never do it here.
    pgrep -x nginx >/dev/null || die "nginx is installed but not running." \
        "It may serve other sites; check why and start it yourself: nginx -t && systemctl start nginx"
    [[ $(supervisorctl pid 2>/dev/null) =~ ^[0-9]+$ ]] || die "supervisord is not running." \
        "Starting it also starts every other program it manages; start it yourself: systemctl start supervisor"
    ok "nginx and supervisor are running"
}

add_safe_directory() {
    git config --global --get-all safe.directory 2>/dev/null | grep -qxF "$PROJECT_FOLDER" && return 0
    git config --global --add safe.directory "$PROJECT_FOLDER"
    ok "added $PROJECT_FOLDER to root's git safe.directory"
}

migrations_out_of_git() {
    local dir=$1
    if [[ -d $dir/.git ]]; then
        [[ -z $(git -C "$dir" ls-files '*/migrations/0*.py') ]]
    else
        grep -qs 'migrations' "$dir/.gitignore"
    fi
}

step_code() {
    step "Getting the code into $PROJECT_FOLDER"
    local target_real current_url
    target_real=$(readlink -f "$PROJECT_FOLDER" 2>/dev/null || true)

    if [[ $target_real == "$SCRIPT_DIR" ]]; then
        ok "deploying in place (deploy.sh is inside the project folder)"
        [[ -d $PROJECT_FOLDER/.git ]] && add_safe_directory
    elif [[ -n $GIT_REPO ]]; then
        if [[ -d $PROJECT_FOLDER/.git ]]; then
            add_safe_directory
            current_url=$(git -C "$PROJECT_FOLDER" remote get-url origin 2>/dev/null || true)
            [[ $current_url == "$GIT_REPO" ]] || warn "origin is '$current_url', not git_repo '$GIT_REPO'; pulling from origin."
            git -C "$PROJECT_FOLDER" fetch -q origin "$GIT_BRANCH"
            git -C "$PROJECT_FOLDER" checkout -q "$GIT_BRANCH"
            git -C "$PROJECT_FOLDER" pull -q --ff-only origin "$GIT_BRANCH"
            ok "pulled $GIT_BRANCH ($(git -C "$PROJECT_FOLDER" rev-parse --short HEAD))"
        else
            if [[ -d $PROJECT_FOLDER && -n $(ls -A "$PROJECT_FOLDER") ]]; then
                die "$PROJECT_FOLDER exists, is not empty and is not a git checkout." \
                    "Empty it, or put deploy.sh and .env.production inside it to deploy in place."
            fi
            git clone -q --branch "$GIT_BRANCH" "$GIT_REPO" "$PROJECT_FOLDER"
            add_safe_directory
            ok "cloned $GIT_REPO ($GIT_BRANCH)"
        fi
        install -m 600 "$CONFIG_FILE" "$PROJECT_FOLDER/.env.production"
    else
        local excludes=(--exclude=.git/ --exclude=venv/ --exclude=.venv/ --exclude=/.env
            --exclude=/staticfiles/ --exclude=/media/ --exclude=/cache/ --exclude=/run/ --exclude=/logs/
            --exclude=__pycache__/ --exclude='*.pyc' --exclude='*.sqlite3' --exclude=.idea/ --exclude=.vscode/)
        # Migrations generated on the server must not be replaced by local ones.
        migrations_out_of_git "$SCRIPT_DIR" && excludes+=(--exclude='*/migrations/0*.py')
        mkdir -p "$PROJECT_FOLDER"
        rsync -a "${excludes[@]}" "$SCRIPT_DIR/" "$PROJECT_FOLDER/"
        ok "copied $SCRIPT_DIR to $PROJECT_FOLDER with rsync (no .git there: update with deploy.sh, not update.sh)"
    fi

    [[ -f $PROJECT_FOLDER/manage.py ]] || die "$PROJECT_FOLDER/manage.py not found; the code is not where project_folder says."

    mkdir -p "$STATIC_DIR" "$MEDIA_DIR" "$CACHE_DIR" "$RUN_DIR" "$LOG_DIR"
    # Files pulled or copied as root would otherwise stay root-owned.
    chown -R "$RUN_USER" "$PROJECT_FOLDER"
    [[ $LOG_DIR == "$PROJECT_FOLDER"/* ]] || chown "$RUN_USER" "$LOG_DIR"
    ok "owner of $PROJECT_FOLDER: $RUN_USER"
}

requirements_hash() { sha256sum "$PROJECT_FOLDER/requirements.txt" | cut -d' ' -f1; }

install_requirements() {
    local stamp=$VENV/.requirements.sha256 hash
    hash=$(requirements_hash)
    if [[ -f $stamp && $(cat "$stamp") == "$hash" ]]; then
        ok "requirements.txt unchanged; skipping pip install"
        return 0
    fi
    info "pip install -r requirements.txt (this can take a few minutes)"
    (cd "$PROJECT_FOLDER" && run_as "$VENV/bin/pip" install -q --disable-pip-version-check -r requirements.txt) ||
        die "pip install failed; see the output above."
    printf '%s\n' "$hash" | run_as tee "$stamp" >/dev/null
    ok "requirements installed"
}

step_venv() {
    step "Python virtualenv and requirements"
    if ! "$VENV/bin/python" -c 'import sys' 2>/dev/null; then
        [[ -e $VENV ]] && { warn "$VENV is broken; recreating it"; rm -rf "$VENV"; }
        run_as "$PY" -m venv "$VENV"
        ok "created $VENV with python $PY_VERSION"
    else
        ok "$VENV exists ($("$VENV/bin/python" -c 'import sys; print("%d.%d" % sys.version_info[:2])'))"
    fi
    install_requirements
}

# Runs SQL from stdin as the postgres superuser. Names and the password reach
# psql as variables read from the environment (:'dbuser', :'dbpass',
# :'dbname'), never spliced into the SQL text or onto a command line.
PG_VARS='\set dbuser `printenv DEPLOY_DB_USER`
\set dbpass `printenv DEPLOY_DB_PASSWORD`
\set dbname `printenv DEPLOY_DB_NAME`'

pg_admin() {
    { printf '%s\n' "$PG_VARS"; cat; } |
        (cd / && DEPLOY_DB_USER=$DB_USER DEPLOY_DB_PASSWORD=$DB_PASSWORD DEPLOY_DB_NAME=$DB_NAME \
            runuser -u postgres -- psql -X -q -tA -v ON_ERROR_STOP=1 -d postgres)
}

step_database() {
    step "PostgreSQL database"
    local role_exists owner err

    if ((DB_LOCAL)) && pg_native_installed; then
        port_open 127.0.0.1 "$DB_PORT" || die "PostgreSQL is installed but nothing listens on port $DB_PORT." \
            "Start it (systemctl start postgresql) or fix database_port, then run again."
        role_exists=$(pg_admin <<< "SELECT 1 FROM pg_roles WHERE rolname = :'dbuser';")
        if [[ $role_exists == 1 ]]; then
            ok "role $DB_USER exists (password left unchanged)"
        else
            pg_admin <<< "SELECT format('CREATE ROLE %I LOGIN PASSWORD %L', :'dbuser', :'dbpass') \\gexec"
            ok "created role $DB_USER"
        fi
        owner=$(pg_admin <<< "SELECT pg_get_userbyid(datdba) FROM pg_database WHERE datname = :'dbname';")
        if [[ -z $owner ]]; then
            pg_admin <<< "SELECT format('CREATE DATABASE %I OWNER %I', :'dbname', :'dbuser') \\gexec"
            ok "created database $DB_NAME owned by $DB_USER"
        elif [[ $owner != "$DB_USER" ]]; then
            die "Database $DB_NAME already exists and belongs to role '$owner', not '$DB_USER'." \
                "It probably belongs to another project. Choose another database_name."
        else
            ok "database $DB_NAME exists"
        fi
    else
        info "database on $DB_HOST:$DB_PORT is not managed by a local PostgreSQL install; only testing the connection"
    fi

    if ! err=$(PGPASSWORD=$DB_PASSWORD PGCONNECT_TIMEOUT=5 psql -X -tA -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -c 'SELECT 1' 2>&1); then
        local why
        case $err in
            *"password authentication failed"*)
                why="The password is wrong. The role $DB_USER already existed and this script never changes passwords of existing roles. Put the right password in .env.production, or change it yourself with: sudo -u postgres psql -c '\\password $DB_USER'" ;;
            *"does not exist"*)
                why="The role or database does not exist on $DB_HOST. Create them there (this script only creates them on a local PostgreSQL)." ;;
            *"no pg_hba.conf entry"*)
                why="pg_hba.conf on the database server does not allow $DB_USER from this host. Add a host/scram-sha-256 line and reload PostgreSQL." ;;
            *"Connection refused"*|*"could not connect"*|*"timeout expired"*)
                why="Nothing accepts connections on $DB_HOST:$DB_PORT. Check database_host/database_port and that PostgreSQL listens there." ;;
            *) why="See the PostgreSQL error above." ;;
        esac
        die "Cannot connect to PostgreSQL as $DB_USER@$DB_HOST:$DB_PORT/$DB_NAME:" "$err" "$why"
    fi
    ok "connected as $DB_USER to $DB_NAME on $DB_HOST:$DB_PORT"
}

step_app_env() {
    step "Writing the app .env"
    SECRET_KEY_NEW=0
    resolve_secret_key
    compute_origins
    local k
    for k in DEBUG ALLOWED_HOSTS CSRF_TRUSTED_ORIGINS CORS_ALLOWED_ORIGINS DATABASE_URL REDIS_HOST REDIS_PORT CACHE_DIR \
        CACHE_KEY_PREFIX STATIC_ROOT MEDIA_ROOT BEHIND_PROXY SESSION_COOKIE_SECURE CSRF_COOKIE_SECURE; do
        [[ -v APP[$k] ]] && warn "$k from .env.production replaces the value deploy.sh would generate"
    done
    if render_app_env | write_if_changed "$APP_ENV" 600 "$RUN_USER:$RUN_GROUP"; then
        ok "wrote $APP_ENV"
    else
        ok "$APP_ENV already up to date"
    fi
    ((SECRET_KEY_NEW)) && info "generated a new SECRET_KEY (kept on later deploys)"
    return 0
}

create_admin() {
    [[ -n $ADMIN_EMAIL ]] || { info "no admin_email set; skipping admin user"; return 0; }
    local result
    result=$(printf '%s\n%s\n' "$ADMIN_EMAIL" "$ADMIN_PASSWORD" | manage shell -c '
import sys
from django.contrib.auth import get_user_model
email = sys.stdin.readline().rstrip("\n")
password = sys.stdin.readline().rstrip("\n")
User = get_user_model()
if User.objects.filter(**{User.USERNAME_FIELD + "__iexact": email}).exists():
    print("exists")
else:
    extra = {f: "Admin" for f in User.REQUIRED_FIELDS if f != "email"}
    User.objects.create_superuser(**{User.USERNAME_FIELD: email}, password=password, **extra)
    print("created")
')
    case $result in
        *created*) ok "created admin user $ADMIN_EMAIL" ;;
        *exists*) ok "admin user $ADMIN_EMAIL exists (password left unchanged)" ;;
        *) die "Could not create the admin user: $result" ;;
    esac
}

run_migrations() {
    manage check --fail-level ERROR >/dev/null || die "Django system check failed; see the output above."
    if migrations_out_of_git "$PROJECT_FOLDER"; then
        manage makemigrations --noinput ||
            die "makemigrations failed. If it needs a default for a new field, add one in the model and run again."
    fi
    manage migrate --noinput
    ok "migrations applied"
    manage collectstatic --noinput -v 0
    ok "static files collected into $STATIC_DIR"
}

step_django() {
    step "Migrations, static files, admin user"
    run_migrations
    create_admin
}

can_traverse() { runuser -u "$NGINX_USER" -- test -x "$1" 2>/dev/null; }

step_permissions() {
    step "Permissions"
    NGINX_USER=$(awk '$1 == "user" { gsub(";", "", $2); print $2; exit }' "$NGINX_DIR/nginx.conf" 2>/dev/null)
    NGINX_USER=${NGINX_USER:-www-data}
    NGINX_GROUP=$(id -gn "$NGINX_USER")

    # Socket folder: only the app user and nginx's group can reach the socket.
    chown "$RUN_USER:$NGINX_GROUP" "$RUN_DIR"
    chmod 2750 "$RUN_DIR"
    chmod 600 "$APP_ENV" "$PROJECT_FOLDER/.env.production" 2>/dev/null || true
    chmod 750 "$LOG_DIR"

    # nginx serves static and media files directly.
    chmod o+x "$PROJECT_FOLDER"
    chmod o+rx "$STATIC_DIR" "$MEDIA_DIR"
    find "$STATIC_DIR" "$MEDIA_DIR" \( -type d ! -perm -o=x \) -exec chmod o+rx {} + -o \( -type f ! -perm -o=r \) -exec chmod o+r {} +

    local dir=$PROJECT_FOLDER
    while dir=$(dirname "$dir"); [[ $dir != / ]]; do
        if ! can_traverse "$dir"; then
            chmod o+x "$dir"
            OUTSIDE_CHANGES+=("chmod o+x $dir (so nginx can reach static/media files)")
            warn "changed permissions outside the project: chmod o+x $dir"
        fi
    done
    can_traverse "$STATIC_DIR" || die "nginx user $NGINX_USER still cannot reach $STATIC_DIR."
    ok "nginx ($NGINX_USER) can reach static/media; socket folder $RUN_DIR is $RUN_USER:$NGINX_GROUP 2750"
}

check_supervisor_result() {
    local out=$1
    if [[ $out == *ERROR* || $out == *FATAL* || $out == *"no such"* ]]; then
        die "supervisor could not start $PROJECT_NAME: $out" "Last lines of $LOG_DIR/gunicorn.log:" \
            "$(tail -n 30 "$LOG_DIR/gunicorn.log" 2>/dev/null)"
    fi
}

step_supervisor() {
    step "Supervisor program [$PROJECT_NAME]"
    local out
    if render_supervisor_conf | write_if_changed "$SUPERVISOR_CONF" 644 root:root; then
        ok "wrote $SUPERVISOR_CONF"
        supervisorctl reread >/dev/null
        out=$(supervisorctl update "$PROJECT_NAME" 2>&1 || true)
        check_supervisor_result "$out"
    else
        ok "$SUPERVISOR_CONF already up to date"
    fi
    out=$(supervisorctl restart "$PROJECT_NAME" 2>&1 || true)
    check_supervisor_result "$out"
    ok "restarted $PROJECT_NAME"
}

nginx_reload() {
    if command -v systemctl >/dev/null && systemctl is-active -q nginx; then
        systemctl reload nginx
    else
        nginx -s reload
    fi
}

step_nginx() {
    step "nginx site $NGINX_SITE"
    local backup='' had_link=0 test_out

    nginx -t >/dev/null 2>&1 || die "nginx -t already fails before any change; another site's config is broken:" \
        "$(nginx -t 2>&1)" "Not touching nginx until that is fixed."
    [[ -L $NGINX_LINK ]] && had_link=1
    if [[ -f $NGINX_SITE ]]; then
        backup=$(mktemp)
        cp -p "$NGINX_SITE" "$backup"
    fi

    if render_nginx_conf | write_if_changed "$NGINX_SITE" 644 root:root || ((had_link == 0)); then
        ln -sfn "$NGINX_SITE" "$NGINX_LINK"
        if ! test_out=$(nginx -t 2>&1); then
            if [[ -n $backup ]]; then
                cp -p "$backup" "$NGINX_SITE"
            else
                rm -f "$NGINX_SITE"
            fi
            ((had_link)) || rm -f "$NGINX_LINK"
            rm -f "$backup"
            die "nginx -t rejected the new site config; the previous config was restored and nginx was not reloaded:" "$test_out"
        fi
        nginx_reload
        ok "nginx config tested and reloaded"
    else
        ok "nginx site already up to date; no reload needed"
    fi
    rm -f "$backup"
    if ((HTTPS_ENABLED)); then
        ok "HTTPS enabled with certificate $CERT_DIR"
    elif ((${#DOMAINS[@]})); then
        info "HTTP only: no certificate in $CERT_DIR yet (see README: Enable HTTPS)"
    fi
    return 0
}

health_check() {
    local proto=http code='' i
    ((HTTPS_ENABLED)) && proto=https
    for i in $(seq 1 30); do
        code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 --unix-socket "$SOCKET" \
            -H "Host: $HEALTH_HOST" -H "X-Forwarded-Proto: $proto" "http://localhost$HEALTH_PATH" || true)
        [[ $code == 200 ]] && break
        sleep 2
    done
    [[ $code == 200 ]] || die "The app did not answer 200 on $HEALTH_PATH through $SOCKET (last status: ${code:-none})." \
        "Last lines of $LOG_DIR/gunicorn.log:" "$(tail -n 30 "$LOG_DIR/gunicorn.log" 2>/dev/null)"
    ok "gunicorn answers 200 on $HEALTH_PATH via the socket"
}

nginx_health_check() {
    local base code
    if ((HTTPS_ENABLED)); then
        base="https://$HEALTH_HOST"
        code=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 10 --resolve "$HEALTH_HOST:443:127.0.0.1" "$base$HEALTH_PATH" || true)
    else
        base="http://127.0.0.1:$NGINX_PORT"
        code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 -H "Host: $HEALTH_HOST" "$base$HEALTH_PATH" || true)
    fi
    [[ $code == 200 ]] || die "nginx returned ${code:-no answer} for $HEALTH_PATH (gunicorn itself is fine)." \
        "Check /var/log/nginx/$PROJECT_NAME.error.log (502 = nginx cannot use $SOCKET)."
    ok "nginx proxies the app (200 on $HEALTH_PATH)"
    if ((HTTPS_ENABLED)); then
        code=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 10 --resolve "$HEALTH_HOST:443:127.0.0.1" "$base/static/admin/css/base.css" || true)
    else
        code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 -H "Host: $HEALTH_HOST" "$base/static/admin/css/base.css" || true)
    fi
    if [[ $code == 200 ]]; then
        ok "nginx serves static files"
    else
        warn "nginx returned $code for /static/admin/css/base.css; check /var/log/nginx/$PROJECT_NAME.error.log"
    fi
}

step_health() {
    step "Health check"
    health_check
    nginx_health_check
}

print_summary() {
    local scheme=http port_suffix='' h c
    ((HTTPS_ENABLED)) && scheme=https
    ((!HTTPS_ENABLED && NGINX_PORT != 80)) && port_suffix=":$NGINX_PORT"
    printf '\n%sDeployed %s%s\n' "$C_BOLD$C_GREEN" "$PROJECT_NAME" "$C_RESET"
    for h in "${HOSTS[@]}"; do
        [[ $h == localhost || $h == 127.0.0.1 ]] && continue
        printf '  URL:         %s://%s%s/\n' "$scheme" "$h" "$port_suffix"
    done
    printf '  Code:        %s (user %s)\n' "$PROJECT_FOLDER" "$RUN_USER"
    printf '  App logs:    %s/gunicorn.log\n' "$LOG_DIR"
    printf '  nginx logs:  /var/log/nginx/%s.{access,error}.log\n' "$PROJECT_NAME"
    printf '  Status:      supervisorctl status %s\n' "$PROJECT_NAME"
    if [[ -d $PROJECT_FOLDER/.git ]]; then
        printf '  Update:      bash %s/update.sh\n' "$PROJECT_FOLDER"
    else
        printf '  Update:      bash %s/deploy.sh   (rsync deploy, no git checkout)\n' "$SCRIPT_DIR"
    fi
    if ((${#DOMAINS[@]} && !HTTPS_ENABLED)); then
        printf '  HTTPS:       once DNS points here: apt install -y certbot python3-certbot-nginx && certbot --nginx -d %s\n' \
            "$(join_by ' -d ' "${DOMAINS[@]}")"
        printf '               then run deploy.sh again so the app switches to secure cookies.\n'
    fi
    if ((${#OUTSIDE_CHANGES[@]})); then
        printf '  Changed outside the project:\n'
        for c in "${OUTSIDE_CHANGES[@]}"; do printf '    - %s\n' "$c"; done
    fi
}

main() {
    set -Eeuo pipefail
    umask 022
    trap 'on_err $? $LINENO "$BASH_COMMAND"' ERR
    step_check_server
    step_preflight
    step_packages
    step_code
    step_venv
    step_database
    step_app_env
    step_permissions
    step_django
    step_supervisor
    step_nginx
    step_health
    print_summary
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    main "$@"
fi
