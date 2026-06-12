# terraform apply — mirrors ADO 'apply' action (Azure stage),
# example resources only. State lives in a Windmill variable.
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
  echo "no remote state yet (http $http) — apply will create from scratch"
fi

export TF_VAR_pet_count="$pet_count"
terraform init -no-color -input=false > /dev/null

terraform apply -auto-approve -no-color -input=false | tee apply.log

# save state back to the windmill variable (update, create on 404)
b64=$(base64 -w0 terraform.tfstate)
code=$(curl -s -o /tmp/upd.log -w '%{http_code}' -X POST \
  -H "Authorization: Bearer $WM_TOKEN" -H 'Content-Type: application/json' \
  -d "{\"value\":\"$b64\"}" \
  "$BASE/api/w/$WM_WORKSPACE/variables/update/$STATE_VAR")
if [ "$code" != "200" ]; then
  curl -s -X POST -H "Authorization: Bearer $WM_TOKEN" -H 'Content-Type: application/json' \
    -d "{\"path\":\"$STATE_VAR\",\"value\":\"$b64\",\"is_secret\":false,\"description\":\"tfstate for labmgr windmill test\"}" \
    "$BASE/api/w/$WM_WORKSPACE/variables/create" > /dev/null
  echo "state variable created"
else
  echo "state variable updated"
fi

PETS=$(terraform output -json pets) APPLY_LOG=apply.log python3 - <<'PY'
import json, os
log = open(os.environ["APPLY_LOG"]).read()
json.dump({
    "action": "apply",
    "applied": True,
    "pets": json.loads(os.environ["PETS"]),
    "apply_log": log[-20000:],
}, open("../result.json", "w"))
PY
