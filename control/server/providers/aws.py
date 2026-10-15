"""
AWS backend: EC2 hosts driven by SSM Run Command, CloudWatch alarms, state in
SSM Parameter Store, tiers deployed as CloudFormation stacks.
"""

import json
import os
from pathlib import Path

import boto3
from botocore.config import Config
from botocore.exceptions import BotoCoreError, ClientError

# What a call to AWS can raise. ClientError is AWS answering "no"; BotoCoreError
# is never reaching an answer - no credentials found, endpoint unreachable, a
# timeout. Catching only ClientError let "no credentials" escape every handler,
# so with no AWS login every endpoint returned a bare 500 instead of the panel
# saying what was wrong.
AWS_ERRORS = (ClientError, BotoCoreError)
from fastapi import HTTPException

from server.providers.base import cached, forget, repo_root

CMD_PREFIX = "nudgebee-scenario-lab:"


class AwsProvider:
    name = "aws"
    labels = {
        "account": "AWS account",
        "agent": "SSM",
        "stack": "Stack",
        "permission": "iam",
        "lab_template": "lab.yaml",
        "waste_template": "waste.yaml",
    }
    # every tier in the catalogue has an AWS implementation
    tiers = ("lab", "services", "db", "full")
    deploy_actions = (
        "cloudformation:CreateStack", "cloudformation:DeleteStack",
        "ec2:RunInstances", "ec2:CreateVpc", "iam:CreateRole", "iam:PassRole",
        "cloudwatch:PutMetricAlarm", "ssm:PutParameter",
    )

    def __init__(self) -> None:
        self.stack = os.environ.get("SCENARIO_LAB_STACK", "nudgebee-scenario-lab")
        self.region = os.environ.get("AWS_REGION", "us-east-1")
        self.infra_dir = Path(os.environ.get("INFRA_DIR", "/app/infra/cloudformation"))
        # The page polls /api/setup, /api/scenarios, /api/alarms and
        # /api/findings on a timer, and most of those make two AWS calls each.
        # FastAPI runs these sync handlers on a 40-thread pool, but botocore
        # defaults to 10 pooled connections per client - so past ~10 concurrent
        # calls the rest queue on the connection pool and the UI looks dead
        # while the process is healthy and idle. Raising the pool to match the
        # thread pool is the fix; the timeouts stop a single wedged AWS call
        # from holding a connection forever.
        cfg = Config(
            region_name=self.region,
            max_pool_connections=50,
            connect_timeout=5,
            read_timeout=20,
            retries={"max_attempts": 3, "mode": "standard"},
        )
        self.ssm = boto3.client("ssm", config=cfg)
        self.ec2 = boto3.client("ec2", config=cfg)
        self.cw = boto3.client("cloudwatch", config=cfg)
        self.sts = boto3.client("sts", config=cfg)
        self.iam = boto3.client("iam", config=cfg)
        self.cfn = boto3.client("cloudformation", config=cfg)
        self.state_param = f"/nudgebee-scenario-lab/{self.stack}/active"
        self.max_param = f"/nudgebee-scenario-lab/{self.stack}/max_minutes"

    # ------------------------------------------------------------- naming

    def template_path(self, tier: str) -> Path:
        if tier not in ("lab", "waste"):
            raise HTTPException(400, "tier must be lab or waste")
        for base in (self.infra_dir, repo_root() / "infra" / "cloudformation"):
            p = base / f"{tier}.yaml"
            if p.exists():
                return p
        raise HTTPException(500, f"{tier}.yaml not found - set INFRA_DIR")

    def stack_name_for(self, tier: str) -> str:
        return self.stack if tier == "lab" else f"{self.stack}-waste"

    # ------------------------------------------------------------- identity

    def _identity(self) -> dict:
        try:
            ident = self.sts.get_caller_identity()
        except AWS_ERRORS as exc:
            return {"error": str(exc)}
        arn = ident["Arn"]
        account = ident["Account"]

        alias = None
        try:
            aliases = self.iam.list_account_aliases().get("AccountAliases", [])
            alias = aliases[0] if aliases else None
        except AWS_ERRORS:
            pass

        # SimulatePrincipalPolicy wants the role ARN, not the assumed-role session.
        policy_arn = arn
        if ":assumed-role/" in arn:
            role = arn.split("/")[1]
            policy_arn = f"arn:aws:iam::{account}:role/{role}"

        return {
            "account": account,
            "account_alias": alias,
            "arn": arn,
            "policy_source_arn": policy_arn,
            "principal": arn.split("/")[-1],
        }

    def identity(self) -> dict:
        return cached("identity", 300, self._identity)

    def _simulate(self, actions: tuple[str, ...]) -> dict[str, bool]:
        """True/False per action. Fails open with {} if simulation is denied."""
        src = self.identity().get("policy_source_arn")
        if not src:
            return {}
        try:
            res = self.iam.simulate_principal_policy(
                PolicySourceArn=src, ActionNames=list(actions)
            )["EvaluationResults"]
        except AWS_ERRORS:
            return {}
        return {r["EvalActionName"]: r["EvalDecision"] == "allowed" for r in res}

    def permissions(self, actions: tuple[str, ...]) -> dict[str, bool]:
        return cached("perm:" + ",".join(sorted(actions)), 300, lambda: self._simulate(actions))

    def can_check_permissions(self) -> bool:
        return bool(self.permissions(("sts:GetCallerIdentity",)))

    def scenario_actions(self, scenario: dict) -> list[str]:
        return list((scenario.get("requires") or {}).get("iam") or [])

    # ------------------------------------------------------------- state

    def max_minutes(self) -> int:
        try:
            return int(self.ssm.get_parameter(Name=self.max_param)["Parameter"]["Value"])
        except AWS_ERRORS:
            return 30

    def read_state(self) -> dict:
        try:
            raw = self.ssm.get_parameter(Name=self.state_param)["Parameter"]["Value"]
            return json.loads(raw or "{}")
        except (*AWS_ERRORS, json.JSONDecodeError):
            return {}

    def write_state(self, state: dict) -> None:
        """
        Update the state parameter, but NEVER create it.

        The parameter is declared by lab.yaml. If this app creates it first -
        which it will, if anyone opens the UI before deploying - CloudFormation's
        AWS::EarlyValidation::ResourceExistenceCheck refuses the whole stack with
        "Validation failed with 1 error(s)" and rolls back, having created nothing.
        That failure names no resource, so it is genuinely hard to diagnose.

        Before the stack exists there are no hosts and therefore no scenarios to
        track, so skipping the write costs nothing.
        """
        try:
            self.ssm.get_parameter(Name=self.state_param)
        except AWS_ERRORS:
            return  # not deployed yet - do not create it
        try:
            self.ssm.put_parameter(
                Name=self.state_param, Value=json.dumps(state), Type="String", Overwrite=True
            )
        except AWS_ERRORS:
            pass

    # ------------------------------------------------------------- hosts

    def lab_hosts(self) -> list[dict]:
        try:
            resp = self.ec2.describe_instances(
                Filters=[
                    {"Name": "tag:nudgebee-scenario-lab", "Values": ["true"]},
                    {"Name": "instance-state-name", "Values": ["running"]},
                ]
            )
        except AWS_ERRORS:
            return []
        online = set()
        try:
            for i in self.ssm.describe_instance_information().get("InstanceInformationList", []):
                if i.get("PingStatus") == "Online":
                    online.add(i["InstanceId"])
        except AWS_ERRORS:
            pass

        out = []
        for res in resp.get("Reservations", []):
            for inst in res.get("Instances", []):
                tags = {t["Key"]: t["Value"] for t in inst.get("Tags", [])}
                # waste-tier resources are tagged too - only include scenario hosts
                if tags.get("nudgebee-finding"):
                    continue
                iid = inst["InstanceId"]
                out.append(
                    {
                        "instance_id": iid,
                        "name": tags.get("Name", iid),
                        # services-tier hosts carry nb-service (order, payment,
                        # inventory, database); the original lab hosts carry neither
                        "role": tags.get("scenario-role", "") or tags.get("nb-service", ""),
                        "service": tags.get("nb-service", ""),
                        "type": inst.get("InstanceType"),
                        "az": inst.get("Placement", {}).get("AvailabilityZone"),
                        "private_ip": inst.get("PrivateIpAddress"),
                        "ssm_online": iid in online,
                    }
                )
        return sorted(out, key=lambda h: h["name"])

    def alarm_map(self) -> dict[str, dict]:
        """alarm name -> alarm, for the host prefix used by the lab stack."""
        try:
            alarms = self.cw.describe_alarms(AlarmNamePrefix=f"{self.stack}-host-", MaxRecords=100)
        except AWS_ERRORS:
            return {}
        out = {}
        for a in alarms.get("MetricAlarms", []):
            out[a["AlarmName"]] = {
                "name": a["AlarmName"],
                "state": a["StateValue"],
                "updated": a["StateUpdatedTimestamp"].isoformat()
                if a.get("StateUpdatedTimestamp")
                else None,
                "metric": f'{a.get("Namespace","")}/{a.get("MetricName","")}',
                "threshold": a.get("Threshold"),
            }
        return out

    def stack_info(self) -> dict:
        try:
            s = self.cfn.describe_stacks(StackName=self.stack)["Stacks"][0]
            return {
                "deployed": True,
                "status": s["StackStatus"],
                "healthy": s["StackStatus"] in ("CREATE_COMPLETE", "UPDATE_COMPLETE"),
                "created": s["CreationTime"].isoformat(),
            }
        except AWS_ERRORS:
            return {"deployed": False, "status": None, "healthy": False, "created": None}

    def recent_runs(self) -> dict[str, dict]:
        """Last SSM invocation per scenario, read back from AWS rather than local state."""
        out: dict[str, dict] = {}
        try:
            cmds = self.ssm.list_commands(MaxResults=50).get("Commands", [])
        except AWS_ERRORS:
            return out
        for c in cmds:
            comment = c.get("Comment") or ""
            if not comment.startswith(CMD_PREFIX):
                continue
            sid = comment[len(CMD_PREFIX):].strip()
            if sid in out:
                continue  # list_commands is newest-first
            out[sid] = {
                "command_id": c.get("CommandId"),
                "status": c.get("Status"),
                "requested_at": c["RequestedDateTime"].isoformat()
                if c.get("RequestedDateTime")
                else None,
            }
        return out

    def metric_warning(self, metric: str) -> str | None:
        if "CWAgent" in metric:
            return "alarm depends on the CloudWatch agent publishing this metric"
        return None

    def describe_metric(self, metric: str | None) -> str | None:
        return metric  # the catalogue is written in AWS terms already

    def timing(self, scenario: dict) -> tuple[int, int | None]:
        """(default run seconds, seconds until the alarm) - the catalogue's own."""
        return scenario.get("default_seconds", 300), scenario.get("expect_alarm_secs")

    # ------------------------------------------------------------- commands

    def send(self, instance_id: str, script: str, label: str, run_seconds: int = 0) -> str:
        """Run a shell script on one host. Returns an id that cancel() accepts."""
        try:
            sent = self.ssm.send_command(
                InstanceIds=[instance_id],
                DocumentName="AWS-RunShellScript",
                Comment=f"{CMD_PREFIX} {label}",
                Parameters={"commands": [script]},
                TimeoutSeconds=60,
            )
        except AWS_ERRORS as exc:
            raise HTTPException(502, f"ssm send-command failed: {exc}") from exc
        return sent["Command"]["CommandId"]

    def cancel(self, entry: dict) -> None:
        try:
            self.ssm.cancel_command(CommandId=entry["command_id"], InstanceIds=[entry["instance_id"]])
        except AWS_ERRORS:
            pass

    # ------------------------------------------------------------- cloud-config faults
    # Scenarios with `kind: aws` break the cloud configuration rather than a
    # host, through the control plane's own credentials. Each action returns the
    # state needed to undo it.

    def _lab_security_group(self, name: str) -> str:
        """Resolve a lab security group by its Name tag. Returns the group id.

        Looked up rather than configured because the stack is redeployable: a
        hardcoded id survives exactly until someone rebuilds the lab, and then
        the scenario revokes a rule on a group that no longer exists - or worse,
        on one that has been reissued to something else.
        """
        resp = self.ec2.describe_security_groups(
            Filters=[
                {"Name": "tag:nudgebee-scenario-lab", "Values": ["true"]},
                {"Name": "tag:Name", "Values": [name]},
            ]
        )
        groups = resp.get("SecurityGroups", [])
        if len(groups) != 1:
            raise HTTPException(
                412,
                f"expected exactly one security group tagged Name={name}, found "
                f"{len(groups)} - is the load balancer tier deployed "
                f"(infra/cloudformation/lb.yaml)?",
            )
        return groups[0]["GroupId"]

    def _revoke_alb_ingress(self, params: dict) -> dict:
        """Remove the ALB -> service ingress rule and return what is needed to restore it.

        The undo is computed BEFORE the change and stored in state, not
        reconstructed at cleanup time. Reconstructing it means re-reading a group
        whose rule has already been deleted and guessing what it used to be; if
        that guess is wrong the lab is left broken in a way nobody notices until
        the next demo.
        """
        host_sg = self._lab_security_group(params.get("host_sg_name", f"{self.stack}-hosts"))
        alb_sg = self._lab_security_group(params.get("alb_sg_name", f"{self.stack}-alb"))
        port = int(params.get("port", 8081))

        permission = {
            "IpProtocol": "tcp",
            "FromPort": port,
            "ToPort": port,
            "UserIdGroupPairs": [{"GroupId": alb_sg}],
        }
        try:
            self.ec2.revoke_security_group_ingress(GroupId=host_sg, IpPermissions=[permission])
        except AWS_ERRORS as exc:
            raise HTTPException(502, f"failed to revoke ALB ingress: {exc}") from exc

        return {"host_sg": host_sg, "alb_sg": alb_sg, "port": port}

    def _restore_alb_ingress(self, undo: dict) -> None:
        """Put the rule back. Idempotent: a duplicate rule is success, not a failure."""
        # Description belongs to the group PAIR, not to the permission. At the
        # permission level botocore rejects it as an unknown parameter, and the
        # failure surfaces as a 500 on stop - which is the one code path that
        # must not fail, because nothing else puts the rule back.
        permission = {
            "IpProtocol": "tcp",
            "FromPort": undo["port"],
            "ToPort": undo["port"],
            "UserIdGroupPairs": [
                {
                    "GroupId": undo["alb_sg"],
                    "Description": "ALB to order service - restored by scenario cleanup",
                }
            ],
        }
        try:
            self.ec2.authorize_security_group_ingress(
                GroupId=undo["host_sg"], IpPermissions=[permission]
            )
        except ClientError as exc:
            if exc.response.get("Error", {}).get("Code") == "InvalidPermission.Duplicate":
                return
            raise

    def _actions(self) -> dict:
        return {"revoke_alb_ingress": (self._revoke_alb_ingress, self._restore_alb_ingress)}

    def apply_action(self, scenario_id: str, action: str, params: dict) -> dict:
        if action not in self._actions():
            raise HTTPException(400, f"{scenario_id}: unknown cloud action {action!r}")
        return self._actions()[action][0](params)

    def undo_action(self, action: str, undo: dict) -> None:
        self._actions()[action][1](undo)

    # ------------------------------------------------------------- findings

    def findings_present(self, tags: list[str]) -> dict[str, list]:
        present: dict[str, list] = {t: [] for t in tags}
        if not tags:
            return present
        flt = [{"Name": "tag:nudgebee-finding", "Values": list(tags)}]
        try:
            resp = self.ec2.describe_instances(Filters=flt)
            for res in resp.get("Reservations", []):
                for inst in res.get("Instances", []):
                    t = {x["Key"]: x["Value"] for x in inst.get("Tags", [])}
                    tag = t.get("nudgebee-finding")
                    if tag in present:
                        present[tag].append({"id": inst["InstanceId"], "state": inst["State"]["Name"]})
        except AWS_ERRORS:
            pass
        try:
            for v in self.ec2.describe_volumes(Filters=flt).get("Volumes", []):
                t = {x["Key"]: x["Value"] for x in v.get("Tags", [])}
                tag = t.get("nudgebee-finding")
                if tag in present:
                    present[tag].append({"id": v["VolumeId"], "state": v["State"]})
        except AWS_ERRORS:
            pass
        try:
            for g in self.ec2.describe_security_groups(Filters=flt).get("SecurityGroups", []):
                t = {x["Key"]: x["Value"] for x in g.get("Tags", [])}
                tag = t.get("nudgebee-finding")
                if tag in present:
                    present[tag].append({"id": g["GroupId"], "state": "present"})
        except AWS_ERRORS:
            pass
        return present

    # ------------------------------------------------------------- setup / deploy

    def setup_info(self) -> dict:
        """
        When the lab is not deployed the UI should say how to deploy it, with the
        account's own VPC and subnet filled in - not a placeholder the operator has
        to go and look up.
        """
        vpc = subnet = None
        try:
            vpcs = self.ec2.describe_vpcs(Filters=[{"Name": "isDefault", "Values": ["true"]}])["Vpcs"]
            if not vpcs:
                vpcs = self.ec2.describe_vpcs()["Vpcs"]
            if vpcs:
                vpc = vpcs[0]["VpcId"]
                subs = self.ec2.describe_subnets(
                    Filters=[
                        {"Name": "vpc-id", "Values": [vpc]},
                        {"Name": "map-public-ip-on-launch", "Values": ["true"]},
                    ]
                )["Subnets"]
                if not subs:
                    subs = self.ec2.describe_subnets(
                        Filters=[{"Name": "vpc-id", "Values": [vpc]}]
                    )["Subnets"]
                if subs:
                    subnet = subs[0]["SubnetId"]
        except AWS_ERRORS:
            pass
        return {
            "suggested_vpc": vpc,
            "suggested_subnet": subnet,
            "deploy_command": "./scripts/deploy.sh",
            "waste_command": "./scripts/deploy.sh waste",
            "manual_command": (
                "aws cloudformation deploy \\\n"
                "  --template-file infra/cloudformation/lab.yaml \\\n"
                f"  --stack-name {self.stack} \\\n"
                "  --capabilities CAPABILITY_IAM \\\n"
                f"  --region {self.region}"
            ),
            "teardown_command": f"aws cloudformation delete-stack --stack-name {self.stack} --region {self.region}",
            "deploy_summary": "EC2 hosts, CloudWatch alarms and an isolated VPC",
        }

    def deploy(self, tier: str, vpc_id: str | None, subnet_id: str | None) -> str:
        name = self.stack_name_for(tier)
        body = self.template_path(tier).read_text()

        params = []
        if vpc_id:
            params.append({"ParameterKey": "VpcId", "ParameterValue": vpc_id})
            if not subnet_id:
                raise HTTPException(400, "subnet_id is required when vpc_id is given")
            params.append({"ParameterKey": "SubnetId", "ParameterValue": subnet_id})
        elif tier == "waste":
            # waste.yaml has no network of its own - reuse the lab's
            vpc = subnet = None
            try:
                outs = self.cfn.describe_stacks(StackName=self.stack)["Stacks"][0].get("Outputs", [])
                vpc = next((o["OutputValue"] for o in outs if o["OutputKey"] == "VpcUsed"), None)
            except AWS_ERRORS:
                pass
            if vpc:
                try:
                    subs = self.ec2.describe_subnets(
                        Filters=[{"Name": "vpc-id", "Values": [vpc]}]
                    )["Subnets"]
                    subnet = subs[0]["SubnetId"] if subs else None
                except AWS_ERRORS:
                    pass
            if not vpc or not subnet:
                raise HTTPException(412, "deploy the lab tier first, or supply vpc_id and subnet_id")
            params = [
                {"ParameterKey": "VpcId", "ParameterValue": vpc},
                {"ParameterKey": "SubnetId", "ParameterValue": subnet},
            ]

        try:
            self.cfn.create_stack(
                StackName=name,
                TemplateBody=body,
                Parameters=params,
                Capabilities=["CAPABILITY_IAM"],
                Tags=[{"Key": "nudgebee-scenario-lab", "Value": "true"}],
                OnFailure="ROLLBACK",
            )
        except ClientError as exc:
            code = exc.response.get("Error", {}).get("Code", "")
            if code == "AlreadyExistsException":
                raise HTTPException(409, f"stack {name} already exists") from exc
            raise HTTPException(502, f"create_stack failed: {exc}") from exc
        except BotoCoreError as exc:
            raise HTTPException(502, f"create_stack failed: {exc}") from exc

        forget("identity")
        return name

    def deploy_status(self, tier: str) -> dict:
        name = self.stack_name_for(tier)
        try:
            st = self.cfn.describe_stacks(StackName=name)["Stacks"][0]
        except AWS_ERRORS:
            return {"exists": False, "status": None, "events": [], "in_progress": False}

        events = []
        try:
            for e in self.cfn.describe_stack_events(StackName=name)["StackEvents"][:12]:
                events.append(
                    {
                        "time": e["Timestamp"].isoformat(),
                        "resource": e.get("LogicalResourceId"),
                        "type": e.get("ResourceType"),
                        "status": e.get("ResourceStatus"),
                        "reason": e.get("ResourceStatusReason"),
                    }
                )
        except AWS_ERRORS:
            pass

        status = st["StackStatus"]
        return {
            "exists": True,
            "status": status,
            "in_progress": status.endswith("_IN_PROGRESS"),
            "complete": status in ("CREATE_COMPLETE", "UPDATE_COMPLETE"),
            "failed": "ROLLBACK" in status or "FAILED" in status,
            "events": events,
        }

    def teardown(self, tier: str) -> str:
        name = self.stack_name_for(tier)
        try:
            self.cfn.delete_stack(StackName=name)
        except AWS_ERRORS as exc:
            raise HTTPException(502, f"delete_stack failed: {exc}") from exc
        return name
