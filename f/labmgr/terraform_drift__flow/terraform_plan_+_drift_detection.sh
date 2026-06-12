# terraform plan + drift detection — mirrors ADO 'plan' action:
# -detailed-exitcode, exit 2 => drift (ADO: SucceededWithIssues),
# plan text returned as step result (replaces ADO artifacts).
pet_count="${1:-2}"

set -euo pipefail
export TF_IN_AUTOMATION=1
TF_VERSION="1.9.5"
BASE="${BASE_INTERNAL_URL:-$WM_BASE_URL}"
STATE_VAR="f/labmgr/tfstate"

if ! command -v terraform >/dev/null 2>&1; then
  case "$(uname -m)" in
    aarch64|arm64) TF_ARCH=arm64 ;;
    *)             TF_ARCH=amd64 ;;
  esac
  curl -sSL "https://releases.hashicorp.com/terraform/${TF_VERSION}/terraform_${TF_VERSION}_linux_${TF_ARCH}.zip" -o /tmp/tf.zip
  mkdir -p "$HOME/bin"
  (cd "$HOME/bin" && unzip -qo /tmp/tf.zip)
  export PATH="$HOME/bin:$PATH"
fi
terraform version

mkdir -p tf && cd tf
cat > main.tf <<'EOF'
terraform {
  required_providers {
    random = { source = "hashicorp/random" }
    null   = { source = "hashicorp/null" }
  }
}

variable "pet_count" { type = number }

resource "random_pet" "lab" {
  count  = var.pet_count
  length = 2
}

resource "null_resource" "marker" {
  triggers = { pets = join(",", random_pet.lab[*].id) }
}

output "pets" { value = random_pet.lab[*].id }
EOF

# restore state from windmill variable (stand-in for azurerm backend)
http=$(curl -s -o state.b64 -w '%{http_code}' -H "Authorization: Bearer $WM_TOKEN" \
  "$BASE/api/w/$WM_WORKSPACE/variables/get_value/$STATE_VAR" || true)
if [ "$http" = "200" ]; then
  tr -d '"' < state.b64 | base64 -d > terraform.tfstate
  echo "state restored ($(wc -c < terraform.tfstate) bytes)"
else
  echo "no remote state yet (http $http) — plan will show full create"
fi

export TF_VAR_pet_count="$pet_count"
terraform init -no-color -input=false > /dev/null

set +e
terraform plan -no-color -input=false -detailed-exitcode -out=tfplan > plan.log 2>&1
ec=$?
set -e

case $ec in
  0) drift=false; echo "No changes." ;;
  2) drift=true;  echo "WARNING: drift detected" ;;
  *) cat plan.log; exit $ec ;;
esac

terraform show -no-color tfplan > tfplan.txt

DRIFT=$drift python3 - <<'PY'
import json, os
plan = open("tfplan.txt").read()
json.dump({
    "action": "plan",
    "drift": os.environ["DRIFT"] == "true",
    "plan_text": plan[:100000],
}, open("../result.json", "w"))
PY
