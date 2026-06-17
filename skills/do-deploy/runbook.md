# do-deploy — copy-pasteable runbook

Pure command reference. No prose. Run top-to-bottom for a fresh product; skip to the relevant section if you're partway through.

Replace `<PROJECT_NAME>` (kebab-case) and `<ProductName>` (display) everywhere, or `export` them so the `$PROJECT_NAME` / `$PRODUCT_NAME` substitutions work.

```bash
export PROJECT_NAME="<PROJECT_NAME>"
export PRODUCT_NAME="<ProductName>"
export REGION="nyc3"
```

## 0. Auth prereqs + pick the DO team

DO PATs are team-scoped. Each builder typically has multiple teams registered as named `doctl` contexts. Pick the right one BEFORE creating anything.

```bash
gh auth status

# List all configured doctl contexts (one per team)
doctl auth list

# See which account/team each context points at
for ctx in $(doctl auth list 2>&1 | sed 's/ (current)//'); do
  EMAIL=$(doctl account get --context "$ctx" --format Email --no-header 2>/dev/null)
  UUID=$(doctl account get --context "$ctx" --format UUID --no-header 2>/dev/null)
  echo "$ctx → $EMAIL  team=$UUID"
done

# Switch to the target team
doctl auth switch --context <team-slug>
doctl account get   # confirm

# If the target team isn't in the list yet, add it:
doctl auth init --context <team-slug>   # paste a PAT from that team

# Org-level DO ↔ GitHub OAuth (one-time per team + GH org pair):
# Visit https://cloud.digitalocean.com/apps → Create App → GitHub source → Manage Access
```

## 1. DO Project

```bash
PROJECT_ID=$(doctl projects list --format Name,ID --no-header | awk -v n="$PRODUCT_NAME" '$1==n{print $2}')
if [ -z "$PROJECT_ID" ]; then
  PROJECT_ID=$(doctl projects create --name "$PRODUCT_NAME" \
    --description "$PRODUCT_NAME production + staging" \
    --purpose "Web Application" --environment Production \
    --format ID --no-header)
fi
echo "PROJECT_ID=$PROJECT_ID"
```

## 2. Managed clusters

```bash
doctl databases create "${PROJECT_NAME}-db" \
  --engine pg --version 16 \
  --size db-s-1vcpu-1gb --region "$REGION" --num-nodes 1 \
  --tag "env:prod,product:${PROJECT_NAME}"

doctl databases create "${PROJECT_NAME}-valkey" \
  --engine valkey \
  --size db-s-1vcpu-1gb --region "$REGION" --num-nodes 1 \
  --tag "env:prod,product:${PROJECT_NAME}"

# Wait until online
until doctl databases get "${PROJECT_NAME}-db"     --format Status --no-header | grep -q online; do sleep 10; done
until doctl databases get "${PROJECT_NAME}-valkey" --format Status --no-header | grep -q online; do sleep 10; done

PG_ID=$(doctl databases list --format ID,Name --no-header | awk -v n="${PROJECT_NAME}-db"     '$2==n{print $1}')
VALKEY_ID=$(doctl databases list --format ID,Name --no-header | awk -v n="${PROJECT_NAME}-valkey" '$2==n{print $1}')
echo "PG_ID=$PG_ID  VALKEY_ID=$VALKEY_ID"
```

## 3. Create prod app from app.yaml

```bash
doctl apps create --spec app.yaml
APP_ID=$(doctl apps list --format ID,Spec.Name --no-header | awk -v n="$PROJECT_NAME" '$2==n{print $1}')
echo "APP_ID=$APP_ID"
```

## 4. Seed BETTER_AUTH_SECRET (dashboard step)

```bash
openssl rand -hex 32
# Dashboard → Apps → $PROJECT_NAME → Settings → App-Level Env Vars →
#   BETTER_AUTH_SECRET = <paste> → mark Encrypted → Save
```

## 5. First deploy

```bash
doctl apps create-deployment "$APP_ID"

# Poll until ACTIVE
while true; do
  PHASE=$(doctl apps get "$APP_ID" -o json | jq -r '.[0].active_deployment.phase // .[0].in_progress_deployment.phase')
  echo "phase=$PHASE"
  [ "$PHASE" = "ACTIVE" ] && break
  [ "$PHASE" = "ERROR" ] && { echo "deploy failed — see troubleshoot.md"; break; }
  sleep 15
done

INGRESS=$(doctl apps get "$APP_ID" -o json | jq -r '.[0].default_ingress')
echo "INGRESS=$INGRESS"
```

## 6. Set URL envs, redeploy

```bash
# Dashboard → App-Level Env Vars:
#   BETTER_AUTH_URL      = $INGRESS
#   NEXT_PUBLIC_APP_URL  = $INGRESS
# Save — triggers automatic redeploy.
```

## 7. Smoke-test + assign to project

```bash
curl -f "$INGRESS/api/health"

doctl projects resources assign "$PROJECT_ID" \
  --resource="do:app:$APP_ID" \
  --resource="do:dbaas:$PG_ID" \
  --resource="do:dbaas:$VALKEY_ID"
```

## 8. (optional) Staging app via shared clusters

```bash
# Staging logical DB on the shared PG cluster
doctl databases db create "$PG_ID" "${PROJECT_NAME}_staging"

# Create staging app
doctl apps create --spec app.staging.yaml
STAGING_APP_ID=$(doctl apps list --format ID,Spec.Name --no-header | awk -v n="${PROJECT_NAME}-staging" '$2==n{print $1}')
echo "STAGING_APP_ID=$STAGING_APP_ID"

# Fresh BETTER_AUTH_SECRET for staging
openssl rand -hex 32
# Dashboard → $PROJECT_NAME-staging → BETTER_AUTH_SECRET = <paste>

# Deploy
doctl apps create-deployment "$STAGING_APP_ID"

# Capture ingress, set URL envs, redeploy
STAGING_INGRESS=$(doctl apps get "$STAGING_APP_ID" -o json | jq -r '.[0].default_ingress')
echo "STAGING_INGRESS=$STAGING_INGRESS"
# Dashboard → staging → BETTER_AUTH_URL = $STAGING_INGRESS, NEXT_PUBLIC_APP_URL = $STAGING_INGRESS

# Assign to project
doctl projects resources assign "$PROJECT_ID" --resource="do:app:$STAGING_APP_ID"
```

## Handy post-deploy commands

```bash
doctl apps logs "$APP_ID" --type=run --follow
doctl apps logs "$APP_ID" --type=build
doctl apps list-deployments "$APP_ID"
doctl apps create-deployment "$APP_ID" --force-rebuild   # manual redeploy / rollback base
doctl apps spec get "$APP_ID"                            # confirm live spec matches repo
```
