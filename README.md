# TRDL: The Responding Dark Laughter

An HTTP service that answers 42, and the platform around it: AKS across three availability zones, a Helm chart, Terraform and a GitHub Actions pipeline.

```console
$ curl http://<public-ip>/
42
```

- **Report** (design, reasons, production plan): [REPORT.md](REPORT.md)
- **Developer contract** (what an app must do to run here): [docs/developer-contract.md](docs/developer-contract.md)

## Repository layout

```
app/                    Go service, unit tests, Dockerfile
charts/trdl/            Helm chart: Deployment, Service, HPA, PDB, NetworkPolicy
deploy/poc/values.yaml  Values for the PoC environment on AKS
infra/                  Terraform: resource group, ACR, AKS, public IP, CI identity
infra/bootstrap/        One-time script for the Terraform state storage
tests/e2e/              kind cluster config and end-to-end test scripts
.github/workflows/      CI/CD pipeline
```

## Run and test on your machine

Needs Go 1.27. The e2e target also needs Docker, kind, kubectl and Helm 4.

```bash
make run          # starts on :8080
curl localhost:8080/          # 42
make test         # unit tests
make e2e          # builds the image, starts a 3-zone kind cluster, runs all e2e tests
make e2e-clean
```

## Deploy to Azure

### Before you start

- An Azure subscription where you may create resources, and Owner or User Access Administrator rights on it (Terraform creates role assignments).
- Tools: Azure CLI, Terraform 1.9 or newer, kubectl, kubelogin (`az aks install-cli` installs both), Helm 4, GitHub CLI, jq.
- This repository pushed to GitHub.

### Step 1. Select the subscription

```bash
az login
az account set --subscription "<subscription name or id>"
az account show --query "{name:name, id:id}" -o table   # check it is the right one
export ARM_SUBSCRIPTION_ID="$(az account show --query id -o tsv)"
```

### Step 2. Create the Terraform state storage (once)

```bash
bash infra/bootstrap/state.sh
```

It asks for confirmation, creates `rg-trdl-tfstate` with a storage account, and writes `infra/backend.hcl`.

### Step 3. Create the infrastructure

```bash
cd infra
terraform init -backend-config=backend.hcl
terraform plan  -var github_repository=<owner>/<repo> -out tfplan
terraform apply tfplan
```

Most of the time goes to creating AKS. Commit the generated `.terraform.lock.hcl` so every run uses the same provider build.

### Step 4. Create the app namespace (once)

The CI identity may only write inside the `trdl` namespace, so a cluster admin creates it. Terraform made you cluster admin.

```bash
az aks get-credentials -g rg-trdl-poc -n aks-trdl-poc
kubelogin convert-kubeconfig -l azurecli
kubectl create namespace trdl
```

### Step 5. Connect GitHub to Azure

Create the `poc` environment and copy the Terraform outputs into its variables. None of them is a secret: login uses OIDC, so there is no password to store.

```bash
REPO=<owner>/<repo>
gh api -X PUT "repos/$REPO/environments/poc" > /dev/null
terraform output -json github_variables | jq -r 'to_entries[] | "\(.key) \(.value)"' |
  while read -r key value; do gh variable set "$key" --env poc --body "$value" --repo "$REPO"; done
```

Optional: in GitHub, add required reviewers to the `poc` environment. Then every deploy waits for a click.

### Step 6. Deploy

Push to `main`, or run the workflow by hand from the Actions tab. The pipeline runs the tests, builds the image, tests it on kind, pushes it to ACR, runs `helm upgrade` on AKS and ends with a smoke test through the public IP.

### Step 7. Check

```bash
curl "http://$(terraform -chdir=infra output -raw public_ip)/"
bash tests/e2e/smoke.sh "http://$(terraform -chdir=infra output -raw public_ip)"
kubectl -n trdl get pods -o wide        # 3 pods, on nodes in 3 zones
```

### Remove everything

```bash
helm uninstall trdl -n trdl             # frees the public IP from the load balancer
terraform -chdir=infra destroy -var github_repository=<owner>/<repo>
az group delete -n rg-trdl-tfstate      # the state storage, last
```

## Deploy by hand (without GitHub Actions)

The same steps the pipeline runs, after Step 4:

```bash
ACR=$(terraform -chdir=infra output -raw acr_name)
REGISTRY=$(terraform -chdir=infra output -raw acr_login_server)
TAG=$(git rev-parse --short HEAD)

az acr login -n "$ACR"
docker build --build-arg REVISION="$TAG" -t "$REGISTRY/trdl:$TAG" app
docker push "$REGISTRY/trdl:$TAG"

helm upgrade --install trdl charts/trdl -n trdl \
  -f deploy/poc/values.yaml \
  --set image.repository="$REGISTRY/trdl" --set image.tag="$TAG" \
  --wait --rollback-on-failure --timeout 5m
```

You need push rights on the registry: subscription Owner has them, otherwise ask for `AcrPush`.
