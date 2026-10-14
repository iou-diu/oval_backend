# Oval Backend

Django backend for the Oval e-commerce platform: the admin dashboard (e-commerce, inventory,
accounting, CMS, promotions, reports) and the REST API used by the storefront (`/api/v1/`).

**Stack:** Django 5.1 · Django REST Framework · django-allauth · PostgreSQL · Redis (optional) ·
Typesense (product search) · gunicorn + nginx in production.

---

## Contents

1. [Requirements](#requirements)
2. [Run locally](#run-locally)
3. [Configuration (`.env`)](#configuration-env)
4. [Useful commands](#useful-commands)
5. [Production deployment](#production-deployment)
6. [Updating production](#updating-production)
7. [Enabling HTTPS](#enabling-https)
8. [Troubleshooting](#troubleshooting)

---

## Requirements

| | Version |
|---|---|
| Python | **3.10, 3.11 or 3.12** (3.13 is not supported by the pinned packages yet) |
| PostgreSQL | 12 or newer (SQLite is fine for local development) |
| Redis | optional; without it a file cache is used |
| Typesense | needed for product search |

---

## Run locally

```sh
# 1. Get the code
git clone git@github.com:iou-diu/ecommerce_backend.git oval_backend
cd oval_backend

# 2. Create and activate a virtualenv
python -m venv venv
source venv/bin/activate          # Linux / macOS
venv\Scripts\activate             # Windows (cmd / PowerShell)
source venv/Scripts/activate      # Windows (Git Bash)

# 3. Install dependencies
pip install -r requirements.txt

# 4. Create .env in the project root (see "Configuration" below)

# 5. Create the database tables
python manage.py makemigrations
python manage.py migrate

# 6. Create an admin user
python manage.py createsuperuser

# 7. Start the development server
python manage.py runserver
```

Open http://127.0.0.1:8000/ and log in with the admin user.

> **Migrations are not in git.** Migration files (`apps/*/migrations/0*.py`) are git-ignored and
> generated on each machine, so run `makemigrations` after every pull that changes models.

---

## Configuration (`.env`)

Settings are read from a `.env` file in the project root. It is git-ignored. Minimal local example:

```ini
SECRET_KEY=any-long-random-string
DEBUG=True
ALLOWED_HOSTS=127.0.0.1,localhost

# PostgreSQL ...
DATABASE_URL=postgres://user:password@localhost:5432/oval_db
# ... or SQLite for quick local work
# DATABASE_URL=sqlite:///db.sqlite3

# Redis cache. Leave REDIS_HOST empty to use a file cache instead.
REDIS_HOST=
REDIS_PORT=6379

# Required at startup (dummy values are fine locally)
TYPESENSE_IP=127.0.0.1
TYPESENSE_PORT=8108
TYPESENSE_KEY=xyz
OPENAI_API_KEY=
MAILERSEND_API_KEY=

# Email
EMAIL_HOST=smtp.sendgrid.net
EMAIL_HOST_USER=apikey
EMAIL_HOST_PASSWORD=

# SSLCommerz payment gateway
store_id=
store_passwd=
success_url=http://localhost:3000/payment/success
SSL_VALIDATE_URL=https://sandbox.sslcommerz.com/validator/api/validationserverAPI.php
IS_SSL_SANDBOX=True
```

Other optional settings: `CSRF_TRUSTED_ORIGINS` and `CORS_ALLOWED_ORIGINS` (comma separated, added
to the built-in lists), `STATIC_ROOT`, `MEDIA_ROOT`, `CACHE_DIR`, `CACHE_KEY_PREFIX`,
`BEHIND_PROXY`, `SESSION_COOKIE_SECURE`, `CSRF_COOKIE_SECURE`, `DJANGO_LOG_LEVEL`.

In production you do not write `.env` yourself: `deploy.sh` generates it from `.env.production`.

---

## Useful commands

```sh
# Typesense product search
python manage.py typesense_products schema      # create the collection
python manage.py typesense_products reindex     # (re)index all products
python manage.py typesense_products destroy     # delete the collection
python manage.py typesense_aggregation schema   # popular-queries collection (also: reindex, rules)

# Seed data
python manage.py seed_accounting                # account heads and expense categories
python manage.py populate_accounts              # default account heads and accounts
python manage.py seed_accounting_demo           # demo data for the accounting screens
python manage.py populate_categories            # sample product categories

# Static files (production does this automatically)
python manage.py collectstatic --noinput
```

---

## Production deployment

`deploy.sh` deploys the app on an **Ubuntu 22.04/24.04 or Debian 12** server with one command:
nginx → gunicorn (unix socket, managed by supervisor) → PostgreSQL. It is safe on a server that
already hosts other projects, because it only touches these things outside the project folder:

| What | Where |
|---|---|
| nginx site | `/etc/nginx/sites-available/<project_name>` and its symlink in `sites-enabled/`, tested with `nginx -t` and then reloaded (never restarted) |
| supervisor program | `/etc/supervisor/conf.d/<project_name>.conf`; only this program is restarted |
| PostgreSQL | creates the role and database if missing; never drops anything and never changes an existing password |
| apt packages | installs only missing ones; never upgrades |
| git | adds the project folder to root's `safe.directory` |
| folder permissions | `chmod o+x` on parent folders, only if nginx cannot reach the static files (reported at the end) |

It refuses to continue if another nginx site already uses the same domain, or if a supervisor
program, nginx site or database with the same name belongs to another project.

The venv, static files, media, cache, logs and gunicorn socket (`run/gunicorn.sock`) all stay
inside the project folder.

### 1. Create the app user

The app never runs as root:

```sh
adduser --disabled-password --gecos "" oval
```

### 2. Clone the code (as root)

```sh
git clone git@github.com:iou-diu/ecommerce_backend.git /home/oval/oval_backend
cd /home/oval/oval_backend
```

The URL is an SSH URL, so root needs an SSH deploy key with access to the repository. Otherwise
use the https URL.

### 3. Fill in the configuration

```sh
cp .env.production.example .env.production
chmod 600 .env.production
nano .env.production
```

`.env.production.example` explains every key. The important ones:

| Key | Meaning |
|---|---|
| `project_name` | unique short name (nginx site, supervisor program) |
| `project_folder` | where the code lives, e.g. `/home/oval/oval_backend` |
| `run_user` | the user from step 1 |
| `domain` | comma-separated domains, e.g. `api.example.com` |
| `frontend_urls` | storefront origins allowed for CORS/CSRF, e.g. `https://shop.example.com` |
| `database_*` | PostgreSQL name, user, password, host, port |
| `admin_email`, `admin_password` | optional superuser, created on the first deploy |
| `redis_host` | optional; empty = file cache |
| UPPERCASE keys and `store_*` | app settings, copied unchanged into the app's `.env` |

Values may contain any character (`$`, `#`, quotes, spaces). The file is read line by line, never
executed.

### 4. Deploy

```sh
bash deploy.sh
```

The script prints numbered steps: server checks → conflict checks → packages → code → virtualenv
and requirements → database → app `.env` → permissions → migrations, static files and admin user →
supervisor → nginx → health check. If anything fails, it stops with an explanation of what to fix.
Run it again after fixing.

At the end it prints the URL, the log locations and the next steps.

**Configuration changes:** edit `.env.production`, then run `bash deploy.sh` again. Running it
repeatedly is safe: files that are already correct are left alone, and only the app is restarted.
Do not edit the generated `.env` by hand, because the next deploy overwrites it.

---

## Updating production

```sh
cd /home/oval/oval_backend
bash update.sh
```

This runs `git pull --ff-only`, runs `pip install` only when `requirements.txt` changed, runs
`makemigrations` and `migrate`, then `collectstatic`. It then restarts only this app and checks that
the app answers.

---

## Enabling HTTPS

HTTPS is not set up automatically, because the domain is often not pointed at the server yet. Once
DNS points to the server:

```sh
apt install -y certbot python3-certbot-nginx
certbot --nginx -d api.example.com
bash deploy.sh
```

Running `deploy.sh` again switches the app to secure cookies and https origins. From then on
`deploy.sh` writes the HTTPS configuration itself, so later deploys keep HTTPS. certbot's own
timer renews the certificate.

---

## Troubleshooting

```sh
supervisorctl status oval_backend                     # is the app running?
tail -f /home/oval/oval_backend/logs/gunicorn.log     # app errors and requests
tail -f /var/log/nginx/oval_backend.error.log         # nginx errors
```

| Symptom | Likely cause |
|---|---|
| `502 Bad Gateway` | the app is not running: check `supervisorctl status` and `gunicorn.log` |
| `400 Bad Request` | the domain is not in `domain=`; add it and run `deploy.sh` |
| `403 CSRF verification failed` | the frontend origin is missing from `frontend_urls`, or HTTPS was enabled without re-running `deploy.sh` |
| Login works over https but not over http | expected after HTTPS is enabled (secure cookies) |
| `makemigrations` asks for a default | a new non-null field needs a default in the model |
| App won't start: `... not found. Declare it as envvar` | a required key is missing from `.env.production` |
