#!/usr/bin/env bash
# One-time setup: a storage account for Terraform state.
# Terraform cannot store its state in a resource it creates itself,
# so this runs once with the Azure CLI before the first `terraform init`.
#
# Usage: infra/bootstrap/state.sh   (writes infra/backend.hcl)
set -euo pipefail

LOCATION="${LOCATION:-swedencentral}"
RG="rg-trdl-tfstate"
CONTAINER="tfstate"
SUB_ID="$(az account show --query id -o tsv)"
SA="sttrdl$(echo -n "$SUB_ID" | sha1sum | cut -c1-12)"   # globally unique, stable
ME="$(az ad signed-in-user show --query id -o tsv)"
OUT="$(cd "$(dirname "$0")/.." && pwd)/backend.hcl"

echo "Subscription: $(az account show --query name -o tsv) ($SUB_ID)"
read -r -p "Create Terraform state storage in this subscription? [y/N] " answer
[[ "$answer" == "y" ]] || exit 1

az group create -n "$RG" -l "$LOCATION" -o none
az storage account create -n "$SA" -g "$RG" -l "$LOCATION" \
  --sku Standard_ZRS --kind StorageV2 \
  --min-tls-version TLS1_2 --allow-blob-public-access false \
  --allow-shared-key-access false -o none
az storage account blob-service-properties update -n "$SA" -g "$RG" \
  --enable-versioning true -o none

# Data-plane access with Entra ID, no account keys.
# "|| true" keeps a second run working when the assignment already exists.
az role assignment create --assignee-object-id "$ME" --assignee-principal-type User \
  --role "Storage Blob Data Contributor" \
  --scope "$(az storage account show -n "$SA" -g "$RG" --query id -o tsv)" -o none || true

# Role assignments can take a minute to apply.
for _ in $(seq 1 12); do
  if az storage container create -n "$CONTAINER" --account-name "$SA" --auth-mode login -o none 2>/dev/null; then
    break
  fi
  echo "waiting for role assignment..."
  sleep 10
done

cat > "$OUT" <<EOF
resource_group_name  = "$RG"
storage_account_name = "$SA"
container_name       = "$CONTAINER"
key                  = "trdl-poc.tfstate"
use_azuread_auth     = true
EOF
echo "Wrote $OUT"
