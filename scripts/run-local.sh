#!/usr/bin/env bash
# Run the control UI locally without Docker.
#
# Uses your existing AWS credentials (env vars, AWS_PROFILE, or ~/.aws).
# Binds to 127.0.0.1 only - this is an operator tool, not a service.
#
#   ./scripts/run-local.sh
#   SCENARIO_LAB_STACK=my-stack AWS_PROFILE=sandbox ./scripts/run-local.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENV="$ROOT/.venv"
PORT="${PORT:-8080}"

export SCENARIO_LAB_STACK="${SCENARIO_LAB_STACK:-nudgebee-scenario-lab}"
export AWS_REGION="${AWS_REGION:-us-east-1}"
export CATALOGUE_PATH="$ROOT/scenarios/catalogue.yaml"
export WEB_DIR="$ROOT/control/web"

if [ ! -d "$VENV" ]; then
  echo "Creating virtualenv at .venv"
  python3 -m venv "$VENV"
  "$VENV/bin/pip" install --quiet --upgrade pip
  "$VENV/bin/pip" install --quiet -r "$ROOT/control/requirements.txt"
fi

echo "Stack:  $SCENARIO_LAB_STACK"
echo "Region: $AWS_REGION"
echo "UI:     http://127.0.0.1:$PORT"
echo

cd "$ROOT/control"
exec "$VENV/bin/uvicorn" server.app:app --host 127.0.0.1 --port "$PORT"
