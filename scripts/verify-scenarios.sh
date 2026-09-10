#!/usr/bin/env bash
# Verify that scenarios actually do something, and that the alarms can see it.
#
#   ./scripts/verify-scenarios.sh            # static checks only, free, no AWS writes
#   ./scripts/verify-scenarios.sh --live     # also runs every scenario briefly
#
# Credentials and region come from your environment, exactly as the aws CLI
# takes them:  AWS_PROFILE=sandbox ./scripts/verify-scenarios.sh
#
# Why this exists
# ---------------
# Two defects shipped that shared one signature: a component reported success
# while doing nothing.
#
#   1. cpu_high set NPROC in the outer shell and referenced it inside a
#      single-quoted `bash -c`. The inner shell saw it empty, seq produced an
#      empty list, wait returned immediately. SSM reported *Success* in under a
#      second and the CPU never moved.
#
#   2. Every AWS/EC2 alarm used Period=60 while the instances had basic
#      (5-minute) monitoring. Four of five one-minute buckets were empty and
#      TreatMissingData=notBreaching scored them OK, so the CPU and network
#      alarms could not fire. The stack deployed green regardless.
#
# Neither is visible by reading the code, and neither fails a deploy. So they
# get a check instead of a comment.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REGION="${AWS_REGION:-us-east-1}"
STACK="${SCENARIO_LAB_STACK:-nudgebee-scenario-lab}"
LIVE=0
[ "${1:-}" = "--live" ] && LIVE=1

fail=0
ok(){   printf '  \033[32mPASS\033[0m %s\n' "$1"; }
bad(){  printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=1; }
warn(){ printf '  \033[33mWARN\033[0m %s\n' "$1"; }
hd(){   printf '\n\033[1m%s\033[0m\n' "$1"; }

# ---------------------------------------------------------------- static
hd "Scenario commands are self-contained"
# A variable assigned in the outer shell is not visible inside a
# single-quoted `bash -c`. Referencing one there is defect #1.
python3 - "$ROOT/scenarios/catalogue.yaml" <<'PY'
import yaml, re, sys
bad = 0
for s in yaml.safe_load(open(sys.argv[1]))["scenarios"]:
    cmd = s["command"]
    assigned = set(re.findall(r'^\s*([A-Za-z_]\w*)=', cmd, re.M))
    exported = set(re.findall(r'^\s*export\s+([A-Za-z_]\w*)', cmd, re.M))
    leaked = set()
    for m in re.finditer(r"bash\s+-c\s+'([^']*)'", cmd):
        for v in assigned - exported:
            if re.search(r'\$\{?' + v + r'\b', m.group(1)):
                leaked.add(v)
    if leaked:
        print(f"  \033[31mFAIL\033[0m {s['id']}: {sorted(leaked)} set outside a "
              f"single-quoted 'bash -c' but referenced inside it - the inner "
              f"shell sees it empty")
        bad = 1
    else:
        print(f"  \033[32mPASS\033[0m {s['id']}")
sys.exit(bad)
PY
[ $? -ne 0 ] && fail=1

hd "Every scenario is bounded, and recoverable if it is cut short"
# Two shapes are safe:
#   timeout {{seconds}} ...        - the process dies on its own
#   ... sleep {{seconds}} ; undo   - bounded, but only if a cleanup exists,
#                                    because cancel_command kills the script
#                                    before the undo runs (defect #3)
python3 - "$ROOT/scenarios/catalogue.yaml" <<'PY'
import yaml, sys
bad = 0
for s in yaml.safe_load(open(sys.argv[1]))["scenarios"]:
    cmd, sid = s["command"], s["id"]
    has_cleanup = bool(s.get("cleanup"))
    if "timeout {{seconds}}" in cmd:
        if has_cleanup:
            print(f"  \033[32mPASS\033[0m {sid} (timeout-bounded, cleanup present)")
        else:
            print(f"  \033[31mFAIL\033[0m {sid}: no cleanup - a cancel leaves its "
                  f"processes running")
            bad = 1
    elif "sleep {{seconds}}" in cmd:
        if has_cleanup:
            print(f"  \033[32mPASS\033[0m {sid} (sleep-bounded, cleanup undoes it if cut short)")
        else:
            print(f"  \033[31mFAIL\033[0m {sid}: changes state and undoes it only at "
                  f"the end of its own script - a cancel or a sweeper expiry kills "
                  f"the script first and the change persists forever")
            bad = 1
    else:
        print(f"  \033[31mFAIL\033[0m {sid}: unbounded - could outlive the lab")
        bad = 1
sys.exit(bad)
PY
[ $? -ne 0 ] && fail=1

hd "Cleanup can actually find what its scenario started"
# pkill -f needs a marker that is present in the running command line.
python3 - "$ROOT/scenarios/catalogue.yaml" <<'PY'
import yaml, sys, re
bad = 0
for s in yaml.safe_load(open(sys.argv[1]))["scenarios"]:
    cleanup = s.get("cleanup", "")
    missing = [m for m in re.findall(r"pkill -f '([^']+)'", cleanup)
               if m not in s["command"]]
    if missing:
        print(f"  \033[31mFAIL\033[0m {s['id']}: cleanup greps for {missing} but the "
              f"command never puts that marker on the command line")
        bad = 1
    else:
        print(f"  \033[32mPASS\033[0m {s['id']}")
sys.exit(bad)
PY
[ $? -ne 0 ] && fail=1

# ---------------------------------------------------------------- alarm wiring
hd "Alarm period matches how often the metric is actually published"
if ! aws sts get-caller-identity >/dev/null 2>&1; then
  warn "not authenticated - skipping live alarm/metric checks"
else
  IDS=$(aws cloudformation describe-stacks --stack-name "$STACK" --region "$REGION" \
        --query 'Stacks[0].Outputs[?ends_with(OutputKey,`Id`)].OutputValue' --output text 2>/dev/null)
  if [ -z "$IDS" ] || [ "$IDS" = "None" ]; then
    warn "stack $STACK not deployed - skipping"
  else
    MON=$(aws ec2 describe-instances --instance-ids $IDS --region "$REGION" \
          --query 'Reservations[].Instances[].Monitoring.State' --output text 2>/dev/null | tr '\t' '\n' | sort -u)
    echo "  instance monitoring: $(echo $MON)"
    # EC2 publishes AWS/EC2 metrics every 300s on basic, 60s on detailed.
    # StatusCheckFailed is always 60s, so it is exempt.
    PUBRATE=300; [ "$MON" = "enabled" ] && PUBRATE=60
    while read -r name period ns metric; do
      [ -z "$name" ] && continue
      [ "$ns" != "AWS/EC2" ] && { ok "$name ($ns publishes on its own schedule)"; continue; }
      [ "$metric" = "StatusCheckFailed" ] && { ok "$name (status checks are always 1-minute)"; continue; }
      if [ "$period" -lt "$PUBRATE" ]; then
        bad "$name: Period=${period}s but AWS/EC2 publishes every ${PUBRATE}s - most periods are empty, so this alarm may never fire"
      else
        ok "$name (Period=${period}s >= publish rate ${PUBRATE}s)"
      fi
    done < <(aws cloudwatch describe-alarms --alarm-name-prefix "${STACK}-host-" --region "$REGION" \
             --query 'MetricAlarms[].[AlarmName,Period,Namespace,MetricName]' --output text 2>/dev/null | sort)
  fi
fi

# ---------------------------------------------------------------- live
if [ $LIVE -eq 1 ]; then
  hd "Scenarios actually run (live - starts each briefly on a host)"
  HOST=$(aws cloudformation describe-stacks --stack-name "$STACK" --region "$REGION" \
         --query 'Stacks[0].Outputs[?OutputKey==`Host1Id`].OutputValue' --output text 2>/dev/null)
  if [ -z "$HOST" ] || [ "$HOST" = "None" ]; then
    bad "no host available for live checks"
  else
    for SID in $(python3 -c "
import yaml;print(' '.join(s['id'] for s in yaml.safe_load(open('$ROOT/scenarios/catalogue.yaml'))['scenarios']))"); do
      PARAMS=$(python3 - "$ROOT/scenarios/catalogue.yaml" "$SID" <<'PY'
import yaml, json, sys
c = [s for s in yaml.safe_load(open(sys.argv[1]))["scenarios"] if s["id"] == sys.argv[2]][0]
print(json.dumps({"commands": [c["command"].replace("{{seconds}}", "40")]}))
PY
)
      echo "$PARAMS" > /tmp/.verify-scenario-params.json
      CID=$(aws ssm send-command --instance-ids "$HOST" --region "$REGION" \
            --document-name AWS-RunShellScript --comment "verify: $SID" \
            --parameters file:///tmp/.verify-scenario-params.json \
            --query 'Command.CommandId' --output text 2>/dev/null)
      sleep 15
      ST=$(aws ssm get-command-invocation --command-id "$CID" --instance-id "$HOST" \
           --region "$REGION" --query 'Status' --output text 2>/dev/null)
      case "$ST" in
        InProgress) ok  "$SID still running at T+15s of 40s" ;;
        Success)    bad "$SID reported Success at T+15s of a 40s command - it exited without doing the work" ;;
        *)          bad "$SID status=$ST ($(aws ssm get-command-invocation --command-id "$CID" \
                        --instance-id "$HOST" --region "$REGION" \
                        --query 'StandardErrorContent' --output text 2>/dev/null | head -c 120))" ;;
      esac
      aws ssm cancel-command --command-id "$CID" --region "$REGION" >/dev/null 2>&1
    done
    rm -f /tmp/.verify-scenario-params.json
    echo
    echo "  cleaning up after live checks"
    curl -s --max-time 20 -X POST http://127.0.0.1:8088/api/reset >/dev/null 2>&1 || true
  fi
else
  hd "Live checks"
  echo "  skipped - pass --live to run every scenario briefly on a real host"
fi

hd "Result"
if [ $fail -eq 0 ]; then
  printf '  \033[32mall checks passed\033[0m\n'; exit 0
else
  printf '  \033[31mchecks failed\033[0m\n'; exit 1
fi
