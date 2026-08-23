# Lab 1 (DSO303) — Part A Walkthrough: Environment Setup

You're in WSL Ubuntu (`zeroe@LAPTOP-KL0T24AP`), so every command below is bash — run it in your WSL terminal, not PowerShell.

---

## Step 1 — Identify your system

```bash
uname -s -m
echo "shell = $SHELL"
echo "home = $HOME"
```

Write down the printed `$HOME` value (e.g. `/home/zeroe`) — you'll need the literal absolute path later. Don't substitute `~` for it anywhere a script expects an absolute path.

---

## Step 2 — Verify Docker and Docker Compose

```bash
docker --version
docker info --format '{{.ServerVersion}}'
docker compose version
```

- `docker --version` only checks the client is installed.
- `docker info` actually talks to the daemon — this is the real test.
- `docker compose version` (space, not hyphen) checks the v2 plugin, which is what reads `docker-compose.yml`.

If Docker isn't installed in WSL:

```bash
curl -fsSL https://get.docker.com | sudo sh
sudo usermod -aG docker $USER
newgrp docker
```

If `docker --version` works but `docker compose version` fails:

```bash
sudo apt-get update && sudo apt-get install -y docker-compose-plugin
```

Verify everything works end to end:

```bash
docker run --rm hello-world
```

✅ Checkpoint: client installed, daemon running, Compose v2 present, "Hello from Docker!" printed.

---

## Step 3 — Install the Floci CLI

```bash
curl -fsSL https://floci.io/install.sh | sh
```

(This is the WSL/Linux equivalent of the PowerShell line you tried earlier — you're using this one, not `irm`/`iex`.)

If you'd rather not blindly pipe into `sh`:

```bash
curl -fsSL https://floci.io/install.sh -o floci-install.sh
less floci-install.sh   # read it
sh floci-install.sh     # then run it
```

Verify:

```bash
floci version
```

Expected: `floci CLI 1.x.x` / `server not running` (expected — you haven't started it yet).

If `floci: command not found`:

```bash
export PATH="$HOME/.local/bin:$PATH"
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc
```

---

## Step 4 — Run Floci's diagnostics

```bash
floci doctor
```

Should show Docker installed, daemon reachable, port 4566 available, image available.

If port 4566 is in use:

```bash
sudo lsof -i :4566
```

Stop whatever's using it, or you'll change the port later in `docker-compose.yml` **and** `configs/course.env` together.

---

## Step 5 — Create the course directory structure

```bash
cd ~
mkdir -p aws-floci-course/{labs/lab-01-iam,policies,configs,templates,outputs,screenshots,notes}
mkdir -p aws-floci-course/scripts/{setup,utilities,cleanup}
cd aws-floci-course
pwd
```

Verify:

```bash
find . -type d | sort
```

From here on, stay in `~/aws-floci-course` for the rest of Part A.

---

## Step 6 — Write `.gitignore` and init Git (before any secret exists)

```bash
cat > .gitignore << 'EOF'
# aws-floci-course/.gitignore
# Written BEFORE any secret existed. Keep it that way.

# ---- Command output and SECRETS ----
# NOTE the trailing /* — this matters, see explanation below.
outputs/*
!outputs/.gitkeep

# ---- Generated Compose configuration ----
.env
.env.local

# ---- Emulator state ----
floci-data/
data/
.floci/

# ---- Credentials of every shape ----
*.pem
*.key
*-access-key.json
*credentials*

# ---- OS / editor noise ----
.DS_Store
Thumbs.db
*.swp
.vscode/
.idea/
EOF

touch outputs/.gitkeep
```

> **Why `outputs/*` and not `outputs/`:** if you write `outputs/` alone, Git excludes the whole directory and never looks inside it — so `!outputs/.gitkeep` has no effect and the folder silently vanishes from your repo. `outputs/*` excludes the *contents* while keeping the directory visible, so the negation actually works.

Init the repo and prove the rule works:

```bash
git init -q
git add .gitignore outputs/.gitkeep
git status --short
```

Expected: both files show as `A` (added). If `outputs/.gitkeep` is missing from that list, your `.gitignore` has the wrong form — fix it before continuing.

Now prove a secret gets blocked:

```bash
echo '{"secret":"pretend-this-is-real"}' > outputs/fake-key.json
git status --short
git check-ignore -v outputs/fake-key.json
rm outputs/fake-key.json
```

The fake key should NOT appear in `git status`, and `git check-ignore -v` should name the exact rule that blocked it.

Commit:

```bash
git commit -q -m "chore: ignore secrets before the repo can hold any"
git log --oneline
```

✅ Checkpoint: repo initialized, `.gitignore` is the first commit, `outputs/.gitkeep` tracked, a test secret was demonstrably blocked.

---

## Step 7 — Understand Floci storage modes (read, don't run yet)

Floci has four storage modes, set by `FLOCI_STORAGE_MODE`:

| Mode | Behaviour | Good for |
|---|---|---|
| `memory` (default) | Everything lost when container stops | CI, throwaway tests |
| `hybrid` | In-memory reads, async flush to disk | **Our choice** — development |
| `persistent` | Synchronous disk write on every change | Max safety, slower |
| `wal` | Append-only write-ahead log with compaction | High-write workloads |

**Why `floci start --persist ~/floci-data` is NOT enough:**

1. `--persist` only mounts a host directory — it does **not** set `FLOCI_STORAGE_MODE`. In default `memory` mode, Floci writes almost nothing durable there, and even deletes its own Docker volumes on teardown (because it assumes its own state is disposable).
2. Sidecar services (RDS, ECR, Lambda, etc. — not relevant until later labs) use a *different* variable, `FLOCI_STORAGE_HOST_PERSISTENT_PATH`, which must be an absolute path — Floci does not expand `~`.
3. CLI flags aren't remembered. A plain `floci start`, `floci restart`, or `floci stop --remove` resets to defaults (memory mode) with nothing warning you.

The three settings that actually matter:

```
FLOCI_STORAGE_MODE: hybrid
FLOCI_STORAGE_PERSISTENT_PATH: /app/data                      # container side
FLOCI_STORAGE_HOST_PERSISTENT_PATH: /home/you/floci-data      # host side, ABSOLUTE
```

Optional but recommended, for readable container/volume names:

```
FLOCI_DOCKER_RESOURCE_NAMESPACE: floci-course
```

(Optional per the lab: jot 2 sentences in `notes/lab-01-notes.md` on why `--persist` alone ≠ `FLOCI_STORAGE_MODE=hybrid` — you'll verify your answer against real output in Step 14.)

---

## Step 8 — Write `docker-compose.yml` and `configs/course.env`

### 8.1 `configs/course.env`

```bash
cat > configs/course.env << 'EOF'
# aws-floci-course/configs/course.env
# Contains NO secrets. Safe to commit.
# Sourced by every lab: source ~/aws-floci-course/configs/course.env

# --- Where Floci keeps its state on YOUR machine ---
# MUST be absolute. Floci rejects relative paths.
# $HOME is expanded when this file is SOURCED by bash.
export FLOCI_HOST_DATA_DIR="$HOME/floci-data"

# --- Storage durability ---
# hybrid = in-memory reads, async flush to disk (default here)
# persistent = synchronous write on every change
# wal = append-only write-ahead log
# memory = NOTHING SURVIVES A RESTART (Floci's own default)
export FLOCI_STORAGE_MODE="hybrid"

# --- Container / Compose identity ---
export FLOCI_CONTAINER_NAME="floci"
export FLOCI_COMPOSE_PROJECT="floci-course"

# --- AWS CLI ---
export AWS_PROFILE=floci
export FLOCI_ENDPOINT=http://localhost:4566
export AWS_REGION_COURSE=us-east-1
export ACCOUNT_ID=000000000000

# --- Project naming convention: every resource is prefixed usms- ---
export PROJECT=usms
export COURSE_ROOT="$HOME/aws-floci-course"
EOF
```

> This file deliberately exports `AWS_PROFILE` and nothing else AWS-related — no `AWS_ENDPOINT_URL`, no access keys as env vars. Mixing profiles with env vars makes failures very hard to diagnose (env vars silently win). This course uses **named profiles** throughout.

### 8.2 `docker-compose.yml`

```bash
cat > docker-compose.yml << 'EOF'
# aws-floci-course — pinned Floci environment
# Bring up with: ./scripts/setup/floci-up.sh
# Pause with:    ./scripts/setup/floci-down.sh
# NEVER run:     docker compose down -v

name: floci-course

services:
  floci:
    image: floci/floci:latest
    # Named "floci" on purpose: a stray `floci start` collides loudly
    # instead of quietly shadowing this one.
    container_name: floci
    restart: unless-stopped
    ports:
      - "4566:4566"
      # Sidecar service ports — commented out until needed in later labs.
      # - "5100-5104:5100-5104"   # ECR registries
      # - "6379-6383:6379-6383"   # ElastiCache
      # - "7001-7005:7001-7005"   # RDS proxies
      # - "9200-9209:9200-9209"   # Lambda Runtime API
      # - "9400-9404:9400-9404"   # OpenSearch
    volumes:
      # Lets Floci spawn sidecar containers. Needed from Lab 05 onward; harmless now.
      - /var/run/docker.sock:/var/run/docker.sock
      # Floci's own state (IAM, S3, DynamoDB, ...) on disk.
      # Value comes from .env, written by floci-up.sh as an absolute path.
      - ${FLOCI_HOST_DATA_DIR:?run ./scripts/setup/floci-up.sh, not docker compose directly}:/app/data
    environment:
      FLOCI_STORAGE_MODE: ${FLOCI_STORAGE_MODE:-hybrid}
      FLOCI_STORAGE_PERSISTENT_PATH: /app/data
      FLOCI_STORAGE_HOST_PERSISTENT_PATH: ${FLOCI_HOST_DATA_DIR}
      FLOCI_STORAGE_PRUNE_VOLUMES_ON_DELETE: "false"
      FLOCI_DOCKER_RESOURCE_NAMESPACE: floci-course
      FLOCI_HOSTNAME: floci
      FLOCI_SERVICES_DOCKER_NETWORK: floci-course_default
      FLOCI_SERVICES_ECR_REGISTRY_BASE_PORT: "5100"
      FLOCI_SERVICES_ECR_REGISTRY_MAX_PORT: "5104"
      FLOCI_SERVICES_ELASTICACHE_PROXY_BASE_PORT: "6379"
      FLOCI_SERVICES_ELASTICACHE_PROXY_MAX_PORT: "6383"
      FLOCI_SERVICES_RDS_PROXY_BASE_PORT: "7001"
      FLOCI_SERVICES_RDS_PROXY_MAX_PORT: "7005"
      FLOCI_SERVICES_LAMBDA_RUNTIME_API_BASE_PORT: "9200"
      FLOCI_SERVICES_LAMBDA_RUNTIME_API_MAX_PORT: "9209"
      FLOCI_SERVICES_OPENSEARCH_PROXY_BASE_PORT: "9400"
      FLOCI_SERVICES_OPENSEARCH_PROXY_MAX_PORT: "9404"
    healthcheck:
      test: ["CMD-SHELL", "curl -sf http://localhost:4566/_floci/health || exit 1"]
      interval: 5s
      timeout: 3s
      retries: 30
      start_period: 20s

# There is deliberately no top-level `volumes:` block — everything is a
# host bind mount, so nothing here can be silently deleted by Compose.
EOF
```

Sanity-check it parses:

```bash
docker compose config >/dev/null && echo "compose file is valid"
```

**Expected:** an error like `required variable FLOCI_HOST_DATA_DIR is missing a value: run ./scripts/setup/floci-up.sh instead of docker compose directly`. That's correct — `.env` doesn't exist yet (Step 9 writes it). If you instead see "compose file is valid," delete a stale `.env` with `rm -f .env` and retry.

---

## Step 9 — Write the start/stop scripts and bring Floci up

### 9.1 `scripts/setup/floci-up.sh`

```bash
cat > scripts/setup/floci-up.sh << 'EOF'
#!/usr/bin/env bash
# Start the course Floci environment with durable storage. Idempotent.
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
source "$REPO_ROOT/configs/course.env"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$1"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$1" >&2; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$1" >&2; exit 1; }

command -v docker >/dev/null || die "docker not found on PATH"
docker info >/dev/null 2>&1 || die "Docker is not running. Start Docker and retry."

case "$FLOCI_HOST_DATA_DIR" in
  /*) ;;
  *) die "FLOCI_HOST_DATA_DIR must be ABSOLUTE, got: $FLOCI_HOST_DATA_DIR" ;;
esac

# Refuse to fight a container this project did not create
if docker container inspect "$FLOCI_CONTAINER_NAME" >/dev/null 2>&1; then
  owner="$(docker container inspect "$FLOCI_CONTAINER_NAME" \
    --format '{{ index .Config.Labels "com.docker.compose.project" }}' 2>/dev/null || true)"
  if [ "$owner" != "$FLOCI_COMPOSE_PROJECT" ]; then
    warn "A container named '$FLOCI_CONTAINER_NAME' exists but Compose did not create it."
    warn "It was almost certainly started by 'floci start' and its data is not persisted."
    warn "Remove it, then re-run this script:"
    warn "  floci stop --remove   # or: docker rm -f $FLOCI_CONTAINER_NAME"
    die "Refusing to continue."
  fi
fi

mkdir -p "$FLOCI_HOST_DATA_DIR"
log "State directory: $FLOCI_HOST_DATA_DIR"

# Compose does not expand "~", so hand it an absolute, fully expanded path.
cat > "$REPO_ROOT/.env" <<ENVEOF
# GENERATED by scripts/setup/floci-up.sh — do not edit, do not commit.
FLOCI_HOST_DATA_DIR=$FLOCI_HOST_DATA_DIR
FLOCI_STORAGE_MODE=$FLOCI_STORAGE_MODE
ENVEOF

log "Starting Floci (storage mode: $FLOCI_STORAGE_MODE)"
docker compose up -d

log "Waiting for the AWS endpoint to become healthy..."
deadline=$(( $(date +%s) + 180 ))
until curl -sf "http://localhost:4566/_floci/health" >/dev/null 2>&1; do
  if [ "$(date +%s)" -ge "$deadline" ]; then
    docker compose logs --tail 50 floci >&2 || true
    die "Floci did not become healthy within 180s (logs above)."
  fi
  sleep 2
done

# Prove the mount is real, not a phantom volume
mount_src="$(docker container inspect "$FLOCI_CONTAINER_NAME" \
  --format '{{ range .Mounts }}{{ if eq .Destination "/app/data" }}{{ .Type }}:{{ .Source }}{{ end }}{{ end }}')"
case "$mount_src" in
  bind:*) log "Verified /app/data -> ${mount_src#bind:}" ;;
  "")     die "/app/data is not mounted at all. Check docker-compose.yml." ;;
  *)      warn "/app/data is a '$mount_src', not a host bind mount." ;;
esac

log "Floci is up at $FLOCI_ENDPOINT"
EOF

chmod +x scripts/setup/floci-up.sh
```

### 9.2 `scripts/setup/floci-down.sh`

```bash
cat > scripts/setup/floci-down.sh << 'EOF'
#!/usr/bin/env bash
# Pause Floci. YOUR STATE IS KEPT.
#
# docker compose stop     -> container stopped, state kept  <-- this
# docker compose down     -> container removed, bind mount kept
# docker compose down -v  -> container removed, VOLUMES DESTROYED <-- never
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
source "$REPO_ROOT/configs/course.env"

docker compose stop
printf '\033[1;34m==>\033[0m Floci stopped. State preserved in %s\n' "$FLOCI_HOST_DATA_DIR"
EOF

chmod +x scripts/setup/floci-down.sh
```

### 9.3 Start it

```bash
./scripts/setup/floci-up.sh
```

First run pulls the image — can take a few minutes.

Verify three independent ways:

```bash
docker compose ps
floci status
curl -s http://localhost:4566/_floci/health | head -c 300; echo
```

The `curl` is the most convincing — it's a raw HTTP request that doesn't go through Docker or the Floci CLI at all.

Learn these commands now — you'll use them constantly:

```bash
./scripts/setup/floci-up.sh      # start or resume — safe to run any time
./scripts/setup/floci-down.sh    # pause, state kept
docker compose ps                # is it running and healthy?
docker compose logs -f floci     # stream server logs — best debugging tool
floci status / floci logs / floci services
```

> ⚠️ **Never run:** `docker compose down -v` (deletes volumes), `docker volume prune` (unfiltered), `floci start ...` (bypasses Compose, recreates the Step 7 bug), `rm -rf ~/floci-data` (that's your IAM state).

✅ Checkpoint: container running under Compose project `floci-course`, endpoint `http://localhost:4566`, storage hybrid + bind-mounted to `~/floci-data`, health verified independently by `curl`.

---

## Step 10 — Install AWS CLI v2

```bash
curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o awscliv2.zip
unzip -q awscliv2.zip
sudo ./aws/install
rm -rf aws awscliv2.zip
```

(Use `awscli-exe-linux-aarch64.zip` instead if `uname -m` from Step 1 said `aarch64`/`arm64`.)

Verify:

```bash
aws --version
```

Must say `aws-cli/2.x` — ideally 2.13+ (needed for the `endpoint_url` profile setting). If you get v1, `pip uninstall awscli` and reinstall v2.

Explore built-in help (press `q` to quit the pager):

```bash
aws help
aws iam help
aws iam create-user help
```

---

## Step 11 — Understand credentials, regions, profiles (concept, no commands)

Every AWS CLI command needs 4 values:

| Value | What it is | Our value (Floci) |
|---|---|---|
| Access Key ID | Public half of credential pair | `test` |
| Secret Access Key | Private half, signs requests | `test` |
| Region | Which AWS "copy" | `us-east-1` |
| Endpoint URL | Which server to hit | `http://localhost:4566` |

IAM is a **global** service (not region-scoped) — but the CLI still needs a region to send the request somewhere.

A **profile** is a named bundle of these values in `~/.aws/credentials` (secrets) and `~/.aws/config` (settings). Credential resolution order (first match wins): CLI flags → env vars → `~/.aws/credentials` → `~/.aws/config` → attached IAM role.

> ⚠️ Don't mix `eval $(floci env)` (which exports env vars) with `--profile floci` — env vars silently win over profiles, and debugging gets confusing. This course sticks to named profiles.

---

## Step 12 — Create the `floci` AWS CLI profile

```bash
aws configure set aws_access_key_id test --profile floci
aws configure set aws_secret_access_key test --profile floci
aws configure set region us-east-1 --profile floci
aws configure set output json --profile floci
aws configure set endpoint_url http://localhost:4566 --profile floci
```

Verify:

```bash
cat ~/.aws/config
cat ~/.aws/credentials
```

Expected:

```ini
# ~/.aws/config
[profile floci]
region = us-east-1
output = json
endpoint_url = http://localhost:4566

# ~/.aws/credentials
[floci]
aws_access_key_id = test
aws_secret_access_key = test
```

(Note the asymmetry: `[profile floci]` in config, `[floci]` in credentials — genuine AWS CLI behaviour, not a typo.)

Make it the default for this course:

```bash
source configs/course.env
echo 'source ~/aws-floci-course/configs/course.env' >> ~/.bashrc
```

If your AWS CLI predates 2.13 and ignores `endpoint_url`, add this to `course.env` as a fallback:

```bash
export AWS_ENDPOINT_URL=http://localhost:4566
```

---

## Step 13 — First AWS CLI command + the `whoami` helper

```bash
aws sts get-caller-identity --profile floci
```

Expected:

```json
{
    "UserId": "AKIAIOSFODNN7EXAMPLE",
    "Account": "000000000000",
    "Arn": "arn:aws:iam::000000000000:root"
}
```

`Account: 000000000000` is Floci's fixed dummy account — your proof you're not on real AWS.

If you get `Could not connect to the endpoint URL`, Floci isn't running: `./scripts/setup/floci-up.sh`.

Now wrap it in a reusable script:

```bash
cat > scripts/utilities/whoami.sh << 'EOF'
#!/usr/bin/env bash
# Print exactly which identity and endpoint the AWS CLI is currently using,
# and refuse to stay quiet if it is not Floci.
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$REPO_ROOT/configs/course.env"

echo "AWS_PROFILE          = ${AWS_PROFILE:-<unset>}"
echo "AWS_ENDPOINT_URL     = ${AWS_ENDPOINT_URL:-<unset, using profile>}"
echo "configured endpoint  = $(aws configure get endpoint_url || echo '<none>')"
echo "configured region    = $(aws configure get region || echo '<none>')"
echo "---"
aws sts get-caller-identity --output table

acct="$(aws sts get-caller-identity --query Account --output text)"
if [ "$acct" = "$ACCOUNT_ID" ]; then
  printf '\033[1;32m[ok] Account %s — this is Floci, not real AWS.\033[0m\n' "$acct"
else
  printf '\033[1;31m[DANGER] Account %s is NOT the Floci account (%s).\033[0m\n' "$acct" "$ACCOUNT_ID"
  printf '\033[1;31mYou may be pointed at REAL AWS. Stop and re-check your profile.\033[0m\n'
  exit 1
fi
EOF

chmod +x scripts/utilities/whoami.sh
./scripts/utilities/whoami.sh
```

✅ Checkpoint: AWS CLI → Floci working, account `000000000000`, `whoami.sh` written and passing.

---

## Step 14 — Prove isolation AND prove persistence (two separate proofs!)

**14.1/14.2 — Isolation: inspect the actual URL used**

```bash
aws sts get-caller-identity --profile floci --debug 2>&1 \
  | grep -i "endpoint\|Making request" \
  | head -5
```

Look for `http://localhost:4566` in the output — not `amazonaws.com`.

**14.3 — Isolation: stop the container, confirm the CLI breaks**

```bash
./scripts/setup/floci-down.sh
aws sts get-caller-identity --profile floci
```

Expected: `Could not connect to the endpoint URL: "http://localhost:4566/"`. If your commands were secretly hitting real AWS, stopping a local container couldn't break them.

**14.4 — Persistence: create something, restart, check it survived**

```bash
# 1. Bring Floci back up
./scripts/setup/floci-up.sh

# 2. Create a marker resource
aws iam create-user --user-name persistence-check --output text --query 'User.Arn'

# 3. Full restart, not just a pause
docker compose restart floci
sleep 5
until curl -sf http://localhost:4566/_floci/health >/dev/null 2>&1; do sleep 2; done

# 4. Is it still there?
aws iam get-user --user-name persistence-check --query 'User.UserName' --output text
```

Expected final line: `persistence-check`. If instead you get `NoSuchEntity`, your storage config is wrong — go back to Step 7/8.

Check the data on disk:

```bash
ls -la ~/floci-data
du -sh ~/floci-data
```

Clean up the marker:

```bash
aws iam delete-user --user-name persistence-check
```

**14.5 — Exit codes**

```bash
aws sts get-caller-identity --profile floci > /dev/null 2>&1; echo "exit code = $?"
aws iam get-user --user-name does-not-exist > /dev/null 2>&1; echo "exit code = $?"
```

Expected: `0` then `254` (AWS CLI v2 uses 254 for a service-side error like `NoSuchEntity`, 255 for client/connection errors).

> Floci accepts any non-empty credentials — `get-caller-identity` here proves *connectivity*, not real authentication like it would against actual AWS.

✅ Checkpoint: isolation proven 3 ways (account, URL, breaks when stopped), persistence proven (create → restart → still there), `~/floci-data` has real files.

---

## Step 15 — Storage diagnostics script, README, commit Part A

### 15.1 `scripts/utilities/floci-storage-check.sh`

```bash
cat > scripts/utilities/floci-storage-check.sh << 'EOF'
#!/usr/bin/env bash
# Diagnose "my data disappeared" / "new Docker volumes keep appearing".
# Read-only. Destroys nothing. Paste its output into your lab report.
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$REPO_ROOT/configs/course.env"

ok()   { printf '\033[1;32m[ok]\033[0m %s\n' "$1"; }
bad()  { printf '\033[1;31m[FAIL]\033[0m %s\n' "$1"; }
note() { printf '    %s\n' "$1"; }
hdr()  { printf '\n\033[1;34m=== %s ===\033[0m\n' "$1"; }

envof() {
  docker container inspect "$FLOCI_CONTAINER_NAME" \
    --format '{{ range .Config.Env }}{{ println . }}{{ end }}' | sed -n "s/^$1=//p"
}

hdr "1. Container, and who created it"
if ! docker container inspect "$FLOCI_CONTAINER_NAME" >/dev/null 2>&1; then
  bad "No container named '$FLOCI_CONTAINER_NAME'. Run ./scripts/setup/floci-up.sh"
  exit 1
fi
note "status: $(docker container inspect "$FLOCI_CONTAINER_NAME" --format '{{.State.Status}}')"
proj="$(docker container inspect "$FLOCI_CONTAINER_NAME" \
  --format '{{ index .Config.Labels "com.docker.compose.project" }}')"
if [ "$proj" = "$FLOCI_COMPOSE_PROJECT" ]; then
  ok "Created by Compose project '$FLOCI_COMPOSE_PROJECT'."
else
  bad "NOT created by Compose (project label = '$proj')."
  note "This is a 'floci start' container. Fix: floci stop --remove && ./scripts/setup/floci-up.sh"
fi

hdr "2. Storage mode — the usual culprit"
mode="$(envof FLOCI_STORAGE_MODE)"; mode="${mode:-<unset>}"
if [ "$mode" = "memory" ] || [ "$mode" = "<unset>" ]; then
  bad "FLOCI_STORAGE_MODE=$mode"
  note "Floci defaults to 'memory'. Nothing survives a restart, and Floci deletes"
  note "its own volumes on teardown — hence 'a new volume every time'."
  note "Fix: FLOCI_STORAGE_MODE=hybrid in configs/course.env, then floci-up.sh"
else
  ok "FLOCI_STORAGE_MODE=$mode (durable)"
fi

hdr "3. Is /app/data a real host directory?"
m="$(docker container inspect "$FLOCI_CONTAINER_NAME" \
  --format '{{ range .Mounts }}{{ if eq .Destination "/app/data" }}{{ .Type }} {{ .Source }}{{ end }}{{ end }}')"
if [ -z "$m" ]; then
  bad "/app/data is not mounted — state dies with the container."
else
  set -- $m
  if [ "$1" = "bind" ]; then
    ok "bind mount -> $2"
    [ "$2" = "$FLOCI_HOST_DATA_DIR" ] || bad "...but that is NOT $FLOCI_HOST_DATA_DIR"
  else
    bad "/app/data is a Docker '$1', not your host directory."
    note "A literal '~' in the path is the usual cause; nothing expands it."
  fi
fi

hdr "4. Sidecar storage (RDS / OpenSearch / MSK / ECR)"
hp="$(envof FLOCI_STORAGE_HOST_PERSISTENT_PATH)"
if [ -z "$hp" ]; then
  bad "FLOCI_STORAGE_HOST_PERSISTENT_PATH is unset — sidecars use anonymous volumes."
elif [ "${hp#/}" = "$hp" ]; then
  bad "FLOCI_STORAGE_HOST_PERSISTENT_PATH='$hp' is not absolute. Floci rejects it."
else
  ok "FLOCI_STORAGE_HOST_PERSISTENT_PATH=$hp"
fi

hdr "5. Floci-managed volumes on this machine"
vols="$(docker volume ls -q --filter label=floci=true || true)"
if [ -z "$vols" ]; then
  note "(none — expected while everything is bind-mounted)"
else
  printf '%s\n' "$vols" | sed 's/^/    /'
  note "Count: $(printf '%s\n' "$vols" | wc -l | tr -d ' ')"
  note "Growing on every restart? Storage mode is still wrong."
fi

hdr "6. Host state directory"
if [ -d "$FLOCI_HOST_DATA_DIR" ]; then
  ok "$FLOCI_HOST_DATA_DIR exists (size: $(du -sh "$FLOCI_HOST_DATA_DIR" 2>/dev/null | cut -f1))"
  ls -1 "$FLOCI_HOST_DATA_DIR" 2>/dev/null | head -20 | sed 's/^/    /'
  [ -n "$(ls -A "$FLOCI_HOST_DATA_DIR" 2>/dev/null)" ] || bad "Directory is EMPTY — see checks 2 and 3."
else
  bad "$FLOCI_HOST_DATA_DIR does not exist."
fi

printf '\n'
EOF

chmod +x scripts/utilities/floci-storage-check.sh
./scripts/utilities/floci-storage-check.sh
```

Expected: six sections, all `[ok]`. Keep this output for your lab report.

### 15.2 Cleanup script for stray volumes (optional, only if you ran `floci start` earlier)

```bash
cat > scripts/cleanup/floci-prune-volumes.sh << 'EOF'
#!/usr/bin/env bash
# DESTRUCTIVE. Removes dangling Docker volumes labelled floci=true.
# Your bind-mounted state in $FLOCI_HOST_DATA_DIR is NOT touched.
# dry run : ./scripts/cleanup/floci-prune-volumes.sh
# delete  : ./scripts/cleanup/floci-prune-volumes.sh --yes
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$REPO_ROOT/configs/course.env"
CONFIRM="${1:-}"

vols="$(docker volume ls -q --filter label=floci=true --filter dangling=true || true)"
if [ -z "$vols" ]; then
  printf '\033[1;32m[ok]\033[0m No dangling floci volumes.\n'; exit 0
fi

count="$(printf '%s\n' "$vols" | wc -l | tr -d ' ')"
printf '\033[1;33m[!]\033[0m %s dangling volume(s) labelled floci=true:\n' "$count"
printf '%s\n' "$vols" | sed 's/^/    /'

if [ "$CONFIRM" != "--yes" ]; then
  printf '\nDry run. Re-run with --yes to delete these.\n'
  printf 'Your lab state in %s is unaffected either way.\n' "$FLOCI_HOST_DATA_DIR"
  exit 0
fi

printf '%s\n' "$vols" | xargs -r docker volume rm
printf '\033[1;32m[ok]\033[0m Removed %s volume(s).\n' "$count"
EOF

chmod +x scripts/cleanup/floci-prune-volumes.sh
./scripts/cleanup/floci-prune-volumes.sh
```

### 15.3 `README.md`

```bash
cat > README.md << 'EOF'
# AWS CLI + Floci — USMS Course Project

Infrastructure for the **University Student Management System (USMS)**, built lab by lab
with the AWS CLI against [Floci](https://floci.io), a local AWS emulator.

## Quick start

```bash
source configs/course.env
./scripts/setup/floci-up.sh
./scripts/utilities/whoami.sh
```

## Daily workflow

```bash
./scripts/setup/floci-up.sh      # start or resume (idempotent)
# ... lab work ...
./scripts/setup/floci-down.sh    # pause; state is kept
```

## Never run these

| Command | Why |
|---|---|
| `docker compose down -v` | `-v` deletes volumes |
| `docker volume prune` | Unfiltered; use `scripts/cleanup/floci-prune-volumes.sh` |
| `floci start ...` | Bypasses Compose; disables persistence |
| `rm -rf ~/floci-data` | That directory is the IAM state |

## Labs

| Lab | Topic | Status |
|---|---|---|
| 01 | IAM | [x] complete |
| 02 | VPC | [ ] not started |

## Conventions

- All resources are prefixed `usms-`
- Region: `us-east-1` · Floci account: `000000000000`
- Storage mode: `hybrid`, bind-mounted to `~/floci-data`
- Secrets live in `outputs/` and are **never** committed
EOF
```

### 15.4 Commit Part A

```bash
git status --short
```

Confirm nothing under `outputs/` and no `.env` shows up, then:

```bash
git add .
git commit -q -m "feat(lab-01): environment bootstrap with durable Floci storage

Floci is pinned by docker-compose.yml with FLOCI_STORAGE_MODE=hybrid and an
absolute host bind mount, because 'floci start --persist' does not enable a
durable storage mode and its flags are not remembered across restarts."
git log --oneline
```

---

## ✅ End of Part A checkpoint

- Docker + Compose v2 running
- Floci: Compose-managed, hybrid storage, port 4566
- Persistence PROVEN by create → restart → read
- AWS CLI v2 installed
- Profile `floci` configured with `endpoint_url`
- Isolation proven three ways
- `~/aws-floci-course` fully committed to Git

**Part B (Steps 16–33) builds the actual IAM foundation** — users, groups, roles, policies, ARNs, `sts assume-role`, access keys, and diagnosing `AccessDenied`. Come back once Part A is green and I'll walk you through that next.
