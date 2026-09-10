#!/usr/bin/env bash
# Run the control UI locally without Docker.
#
# Uses your existing AWS credentials (env vars, AWS_PROFILE, or ~/.aws), the
# same ones the aws CLI picks up.
# Binds to 127.0.0.1 only - this is an operator tool, not a service.
#
#   ./scripts/run-local.sh
#   AWS_PROFILE=sandbox ./scripts/run-local.sh
#   SCENARIO_LAB_STACK=my-stack AWS_REGION=eu-west-1 ./scripts/run-local.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENV="$ROOT/.venv"
PORT="${PORT:-8080}"

export SCENARIO_LAB_STACK="${SCENARIO_LAB_STACK:-nudgebee-scenario-lab}"
export AWS_REGION="${AWS_REGION:-us-east-1}"
export CATALOGUE_PATH="$ROOT/scenarios/catalogue.yaml"
export WEB_DIR="$ROOT/control/web"
export INFRA_DIR="$ROOT/infra/cloudformation"

PY="${PYTHON:-python3}"

if ! "$PY" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 9) else 1)' 2>/dev/null; then
  echo "This needs Python 3.9 or newer. Found: $("$PY" --version 2>&1)"
  echo "Set PYTHON=/path/to/python3 if you have another one installed."
  exit 1
fi

# A virtualenv is bound to the interpreter that made it. Upgrading Python leaves
# .venv pointing at an interpreter that may no longer exist, and the failure is a
# missing-module error from inside the venv rather than anything naming Python -
# so rebuild instead of making someone work that out.
if [ -d "$VENV" ] && ! "$VENV/bin/python" --version >/dev/null 2>&1; then
  echo "Existing .venv was built with a Python that no longer works. Rebuilding."
  rm -rf "$VENV"
fi

if [ ! -d "$VENV" ]; then
  echo "Creating virtualenv at .venv ($("$PY" --version 2>&1))"
  "$PY" -m venv "$VENV"
  "$VENV/bin/pip" install --quiet --upgrade pip
  # Not --quiet: when a dependency has no wheel for this interpreter, pip falls
  # back to building from source and the compiler error is the only useful
  # explanation. Swallowing it leaves "install failed" and nothing to act on.
  if ! "$VENV/bin/pip" install -r "$ROOT/control/requirements.txt"; then
    echo
    echo "Dependency install failed on $("$PY" --version 2>&1)."
    echo "Usually this means a package has no prebuilt wheel for this Python yet."
    echo "Either use an older Python (PYTHON=python3.12 ./scripts/run-local.sh)"
    echo "or report it - the requirements take minimum versions, so a newer"
    echo "release that supports this interpreter should be picked up on its own."
    rm -rf "$VENV"
    exit 1
  fi
fi

if [ -n "${AWS_PROFILE:-}" ]; then
  echo "Profile: $AWS_PROFILE"
else
  # No profile set is fine - it means env credentials or [default] in ~/.aws.
  # Saying so beats leaving someone to wonder which account the UI will act on.
  echo "Profile: (none set - using AWS_ACCESS_KEY_ID or the default profile)"
fi
echo "Stack:   $SCENARIO_LAB_STACK"
echo "Region:  $AWS_REGION"
echo "UI:      http://127.0.0.1:$PORT"
echo

cd "$ROOT/control"
exec "$VENV/bin/uvicorn" server.app:app --host 127.0.0.1 --port "$PORT"
