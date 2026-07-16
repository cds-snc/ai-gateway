#!/usr/bin/env python3

import argparse
import json
import os
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Dict, List, Optional, Sequence, Set, Tuple


REPO_ROOT = Path(__file__).resolve().parents[1]
DEFAULT_STACK_DIR = REPO_ROOT / "terragrunt" / "ai_gateway"
DEFAULT_OUTPUT = DEFAULT_STACK_DIR / "import.generated.tf"
DEFAULT_REPORT = DEFAULT_STACK_DIR / "import-report.json"


@dataclass
class ImportBlock:
    address: str
    import_id: str
    note: Optional[str] = None


class ImportGeneratorError(RuntimeError):
    pass


class AwsCliPaginator:
    def __init__(self, service: "AwsCliService", operation: str):
        self._service = service
        self._operation = operation

    def paginate(self, **kwargs: Any):
        yield self._service.call(self._operation, **kwargs)


class AwsCliService:
    def __init__(self, facade: "AwsFacade", service_name: str):
        self._facade = facade
        self._service_name = service_name

    def call(self, operation: str, **kwargs: Any) -> Dict[str, Any]:
        return self._facade.call(self._service_name, operation, **kwargs)

    def get_paginator(self, operation: str) -> AwsCliPaginator:
        return AwsCliPaginator(self, operation)

    def __getattr__(self, operation: str):
        return lambda **kwargs: self.call(operation, **kwargs)


class AwsFacade:
    def __init__(self, region: str, profile: Optional[str] = None):
        self.region = region
        self.profile = profile
        self.sts = AwsCliService(self, "sts")
        self.ec2 = AwsCliService(self, "ec2")
        self.route53 = AwsCliService(self, "route53")
        self.acm = AwsCliService(self, "acm")
        self.elbv2 = AwsCliService(self, "elbv2")
        self.logs = AwsCliService(self, "logs")
        self.cloudtrail = AwsCliService(self, "cloudtrail")
        self.iam = AwsCliService(self, "iam")
        self.kms = AwsCliService(self, "kms")
        self.s3 = AwsCliService(self, "s3")
        self.secretsmanager = AwsCliService(self, "secretsmanager")
        self.elasticache = AwsCliService(self, "elasticache")
        self.rds = AwsCliService(self, "rds")
        self.ecs = AwsCliService(self, "ecs")
        self.appscaling = AwsCliService(self, "application-autoscaling")

    def call(self, service: str, operation: str, **kwargs: Any) -> Dict[str, Any]:
        command = [
            "aws",
            service,
            operation.replace("_", "-"),
            "--region",
            self.region,
            "--output",
            "json",
        ]
        if kwargs:
            command.extend(["--cli-input-json", json.dumps(kwargs)])
        if self.profile:
            command.extend(["--profile", self.profile])

        completed = subprocess.run(
            command,
            cwd=str(REPO_ROOT),
            capture_output=True,
            text=True,
            check=False,
            env={**os.environ, "AWS_PAGER": ""},
        )
        if completed.returncode != 0:
            raise ImportGeneratorError(
                f"AWS CLI command failed ({' '.join(command)}):\n{completed.stderr.strip() or completed.stdout.strip()}"
            )

        stdout = completed.stdout.strip()
        return json.loads(stdout) if stdout else {}

    def account_id(self) -> str:
        return self.sts.get_caller_identity()["Account"]


def run_cmd(command: Sequence[str], cwd: Path) -> str:
    completed = subprocess.run(
        list(command),
        cwd=str(cwd),
        capture_output=True,
        text=True,
        check=False,
    )
    if completed.returncode != 0:
        raise ImportGeneratorError(
            f"Command failed ({' '.join(command)}):\n{completed.stderr.strip() or completed.stdout.strip()}"
        )
    return completed.stdout


def terragrunt_render(stack_dir: Path) -> Dict[str, Any]:
    output = run_cmd(["terragrunt", "render", "--format", "json", "--no-color"], cwd=stack_dir)
    return json.loads(output)


def terragrunt_state_list(stack_dir: Path) -> Set[str]:
    completed = subprocess.run(
        ["terragrunt", "state", "list", "-no-color"],
        cwd=str(stack_dir),
        capture_output=True,
        text=True,
        check=False,
    )

    if completed.returncode != 0:
        message = (completed.stderr.strip() or completed.stdout.strip()).lower()
        no_state_markers = (
            "no state file was found",
            "no stored state was found",
            "state snapshot was created by terraform",
        )
        if any(marker in message for marker in no_state_markers):
            return set()
        raise ImportGeneratorError(
            "Command failed (terragrunt state list -no-color):\n"
            f"{completed.stderr.strip() or completed.stdout.strip()}"
        )

    return {line.strip() for line in completed.stdout.splitlines() if line.strip()}


def ensure_module_manifest(stack_dir: Path) -> Path:
    matches = list(stack_dir.glob(".terragrunt-cache/*/*/.terraform/modules/modules.json"))
    if matches:
        return matches[0]

    run_cmd(["terragrunt", "init", "-backend=false", "-no-color"], cwd=stack_dir)

    matches = list(stack_dir.glob(".terragrunt-cache/*/*/.terraform/modules/modules.json"))
    if not matches:
        raise ImportGeneratorError("Unable to locate Terraform modules.json after terragrunt init.")
    return matches[0]


def normalize_zone_name(name: str) -> str:
    return name if name.endswith(".") else f"{name}."


def tf_string(value: str) -> str:
    return json.dumps(value)


def render_import_file(imports: Sequence[ImportBlock]) -> str:
    lines = [
        "# Generated by scripts/generate_imports.py",
        "# Review before applying. Unsupported resources are listed in import-report.json.",
        "",
    ]
    for block in imports:
        if block.note:
            lines.append(f"# {block.note}")
        lines.append("import {")
        lines.append(f"  to = {block.address}")
        lines.append(f"  id = {tf_string(block.import_id)}")
        lines.append("}")
        lines.append("")
    return "\n".join(lines).rstrip() + "\n"


def write_json(path: Path, payload: Dict[str, Any]) -> None:
    path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def route53_record_import_id(zone_id: str, name: str, record_type: str) -> str:
    return f"{zone_id}_{normalize_zone_name(name)}_{record_type}"


def sg_rule_import_id(
    security_group_id: str,
    rule_type: str,
    protocol: str,
    from_port: int,
    to_port: int,
    source: str,
) -> str:
    return f"{security_group_id}_{rule_type}_{protocol}_{from_port}_{to_port}_{source}"


def nacl_rule_import_id(network_acl_id: str, rule_number: int, protocol: str, egress: bool) -> str:
    return f"{network_acl_id}:{rule_number}:{protocol}:{str(egress).lower()}"


def route_import_id(route_table_id: str, destination_cidr: str) -> str:
    return f"{route_table_id}_{destination_cidr}"


def role_policy_import_id(role_name: str, policy_name: str) -> str:
    return f"{role_name}:{policy_name}"


def role_policy_attachment_import_id(role_name: str, policy_arn: str) -> str:
    return f"{role_name}/{policy_arn}"


def ecs_service_import_id(cluster_name: str, service_name: str) -> str:
    return f"{cluster_name}/{service_name}"


def appscaling_target_import_id(service_namespace: str, resource_id: str, scalable_dimension: str) -> str:
    return f"{service_namespace}/{resource_id}/{scalable_dimension}"


def appscaling_policy_import_id(
    service_namespace: str,
    resource_id: str,
    scalable_dimension: str,
    policy_name: str,
) -> str:
    return f"{service_namespace}/{resource_id}/{scalable_dimension}/{policy_name}"


class Generator:
    def __init__(self, stack_dir: Path, aws: AwsFacade, config: Dict[str, Any], module_manifest: Dict[str, Any]):
        self.stack_dir = stack_dir
        self.aws = aws
        self.config = config
        self.inputs = config["inputs"]
        self.locals = config["locals"]
        self.module_manifest = module_manifest
        self.imports: List[ImportBlock] = []
        self.skipped: List[Dict[str, str]] = []

        self.name_prefix = self.inputs["name_prefix"]
        self.region = self.inputs["primary_region"]
        self.account_id = aws.account_id()

        self.gateway_domain_name = self.inputs["gateway_domain_name"]
        self.alb_logs_prefix = self.inputs["alb_access_logs_prefix"]
        self.subnet_count = len(self.inputs["subnet_cidrs"])
        self.public_ports = [int(port) for port in self.inputs["approved_public_listener_ports"]]
        self.private_subnet_cidrs = self.inputs["subnet_cidrs"]
        self.public_subnet_cidrs = self.inputs["public_subnet_cidrs"]
        self.vpc_cidr = self.inputs["vpc_cidr"]

    def add(self, address: str, import_id: str, note: Optional[str] = None) -> None:
        self.imports.append(ImportBlock(address=address, import_id=import_id, note=note))

    def skip(self, address: str, reason: str) -> None:
        self.skipped.append({"address": address, "reason": reason})

    def require_one(self, items: Sequence[Any], description: str) -> Any:
        if not items:
            raise ImportGeneratorError(f"Unable to find {description} in AWS.")
        if len(items) > 1:
            raise ImportGeneratorError(f"Expected one {description}, found {len(items)}.")
        return items[0]

    def find_vpc(self) -> Dict[str, Any]:
        response = self.aws.ec2.describe_vpcs(
            Filters=[{"Name": "tag:Name", "Values": [f"{self.name_prefix}_vpc"]}]
        )
        return self.require_one(response["Vpcs"], f"VPC tagged {self.name_prefix}_vpc")

    def find_subnet(self, name: str, tier: str) -> Dict[str, Any]:
        response = self.aws.ec2.describe_subnets(
            Filters=[
                {"Name": "tag:Name", "Values": [name]},
                {"Name": "tag:Tier", "Values": [tier]},
            ]
        )
        return self.require_one(response["Subnets"], f"subnet {name}")

    def find_sg_by_name(self, vpc_id: str, group_name: str) -> Dict[str, Any]:
        response = self.aws.ec2.describe_security_groups(
            Filters=[
                {"Name": "vpc-id", "Values": [vpc_id]},
                {"Name": "group-name", "Values": [group_name]},
            ]
        )
        return self.require_one(response["SecurityGroups"], f"security group {group_name}")

    def find_policy_arn(self, policy_name: str) -> str:
        paginator = self.aws.iam.get_paginator("list_policies")
        for page in paginator.paginate(Scope="Local"):
            for policy in page["Policies"]:
                if policy["PolicyName"] == policy_name:
                    return policy["Arn"]
        raise ImportGeneratorError(f"Unable to find IAM policy {policy_name}.")

    def find_hosted_zone(self) -> Dict[str, Any]:
        response = self.aws.route53.list_hosted_zones_by_name(DNSName=self.gateway_domain_name)
        wanted = normalize_zone_name(self.gateway_domain_name)
        matches = [zone for zone in response["HostedZones"] if zone["Name"] == wanted]
        zone = self.require_one(matches, f"hosted zone {self.gateway_domain_name}")
        zone["CleanId"] = zone["Id"].split("/")[-1]
        return zone

    def find_lb(self) -> Dict[str, Any]:
        response = self.aws.elbv2.describe_load_balancers(Names=[f"{self.name_prefix}-litellm"])
        return self.require_one(response["LoadBalancers"], f"load balancer {self.name_prefix}-litellm")

    def find_tg(self) -> Dict[str, Any]:
        response = self.aws.elbv2.describe_target_groups(Names=[f"{self.name_prefix}-litellm"])
        return self.require_one(response["TargetGroups"], f"target group {self.name_prefix}-litellm")

    def find_lb_listener(self, lb_arn: str, port: int) -> Dict[str, Any]:
        response = self.aws.elbv2.describe_listeners(LoadBalancerArn=lb_arn)
        matches = [listener for listener in response["Listeners"] if listener["Port"] == port]
        return self.require_one(matches, f"listener on port {port}")

    def find_secret(self, name: str) -> Dict[str, Any]:
        paginator = self.aws.secretsmanager.get_paginator("list_secrets")
        for page in paginator.paginate(Filters=[{"Key": "name", "Values": [name]}]):
            for secret in page["SecretList"]:
                if secret["Name"] == name:
                    return secret
        raise ImportGeneratorError(f"Unable to find secret {name}.")

    def find_kms_alias(self, alias_name: str) -> Dict[str, Any]:
        paginator = self.aws.kms.get_paginator("list_aliases")
        for page in paginator.paginate():
            for alias in page["Aliases"]:
                if alias["AliasName"] == alias_name:
                    return alias
        raise ImportGeneratorError(f"Unable to find KMS alias {alias_name}.")

    def find_ecs_service(self, cluster_name: str, service_name: str) -> Dict[str, Any]:
        response = self.aws.ecs.describe_services(cluster=cluster_name, services=[service_name])
        if not response["services"]:
            raise ImportGeneratorError(f"Unable to find ECS service {service_name} in cluster {cluster_name}.")
        return response["services"][0]

    def find_autoscaling_policy(self, resource_id: str, policy_name: str) -> Dict[str, Any]:
        response = self.aws.appscaling.describe_scaling_policies(
            ServiceNamespace="ecs",
            ResourceId=resource_id,
            ScalableDimension="ecs:service:DesiredCount",
            PolicyNames=[policy_name],
        )
        return self.require_one(response["ScalingPolicies"], f"autoscaling policy {policy_name}")

    def generate(self) -> Tuple[List[ImportBlock], List[Dict[str, str]]]:
        vpc = self.find_vpc()
        self.generate_gateway_vpc(vpc)
        self.generate_root_network(vpc)
        self.generate_dns_and_alb(vpc)
        self.generate_logging_and_storage(vpc)
        self.generate_iam(vpc)
        self.generate_secrets_and_redis(vpc)
        self.generate_rds(vpc)
        self.generate_ecs(vpc)
        self.imports.sort(key=lambda block: block.address)
        return self.imports, self.skipped

    def generate_gateway_vpc(self, vpc: Dict[str, Any]) -> None:
        vpc_id = vpc["VpcId"]
        self.add("module.gateway_vpc.aws_vpc.main", vpc_id)

        default_sg = self.require_one(
            self.aws.ec2.describe_security_groups(
                Filters=[
                    {"Name": "vpc-id", "Values": [vpc_id]},
                    {"Name": "group-name", "Values": ["default"]},
                ]
            )["SecurityGroups"],
            f"default security group for {vpc_id}",
        )
        self.add("module.gateway_vpc.aws_default_security_group.default", default_sg["GroupId"])

        default_nacl = self.require_one(
            self.aws.ec2.describe_network_acls(
                Filters=[
                    {"Name": "vpc-id", "Values": [vpc_id]},
                    {"Name": "default", "Values": ["true"]},
                ]
            )["NetworkAcls"],
            f"default network ACL for {vpc_id}",
        )
        self.add("module.gateway_vpc.aws_default_network_acl.default", default_nacl["NetworkAclId"])

        default_rt = self.require_one(
            self.aws.ec2.describe_route_tables(
                Filters=[
                    {"Name": "vpc-id", "Values": [vpc_id]},
                    {"Name": "association.main", "Values": ["true"]},
                ]
            )["RouteTables"],
            f"default route table for {vpc_id}",
        )
        self.skip(
            "module.gateway_vpc.aws_default_route_table.default",
            "aws_default_route_table import can return empty-result in this environment; allow Terraform to adopt/manage default route table without explicit import.",
        )

        igw = self.require_one(
            self.aws.ec2.describe_internet_gateways(
                Filters=[{"Name": "attachment.vpc-id", "Values": [vpc_id]}]
            )["InternetGateways"],
            f"internet gateway for {vpc_id}",
        )
        self.add("module.gateway_vpc.aws_internet_gateway.gw", igw["InternetGatewayId"])

        subnet_names_private: List[str] = []
        subnet_names_public: List[str] = []
        availability_zones = [zone["ZoneName"] for zone in self.aws.ec2.describe_availability_zones()["AvailabilityZones"]]
        for index in range(self.subnet_count):
            az = availability_zones[index]
            private_name = f"{self.name_prefix}_private_subnet_{az}"
            public_name = f"{self.name_prefix}_public_subnet_{az}"
            subnet_names_private.append(private_name)
            subnet_names_public.append(public_name)

            private_subnet = self.find_subnet(private_name, "Private")
            public_subnet = self.find_subnet(public_name, "Public")
            self.add(f"module.gateway_vpc.aws_subnet.private[{index}]", private_subnet["SubnetId"])
            self.add(f"module.gateway_vpc.aws_subnet.public[{index}]", public_subnet["SubnetId"])

        eip = self.require_one(
            self.aws.ec2.describe_addresses(
                Filters=[{"Name": "tag:Name", "Values": [f"{self.name_prefix}-eip0"]}]
            )["Addresses"],
            f"Elastic IP {self.name_prefix}-eip0",
        )
        self.add("module.gateway_vpc.aws_eip.nat[0]", eip["AllocationId"])

        nat = self.require_one(
            self.aws.ec2.describe_nat_gateways(
                Filter=[{"Name": "tag:Name", "Values": [f"{self.name_prefix}-natgw-0"]}]
            )["NatGateways"],
            f"NAT gateway {self.name_prefix}-natgw-0",
        )
        self.add("module.gateway_vpc.aws_nat_gateway.nat_gw[0]", nat["NatGatewayId"])

        main_nacl = self.require_one(
            self.aws.ec2.describe_network_acls(
                Filters=[
                    {"Name": "vpc-id", "Values": [vpc_id]},
                    {"Name": "tag:Name", "Values": [f"{self.name_prefix}_main_nacl"]},
                ]
            )["NetworkAcls"],
            f"network ACL {self.name_prefix}_main_nacl",
        )
        main_nacl_id = main_nacl["NetworkAclId"]
        self.add("module.gateway_vpc.aws_network_acl.main", main_nacl_id)

        route_tables = self.aws.ec2.describe_route_tables(
            Filters=[{"Name": "vpc-id", "Values": [vpc_id]}]
        )["RouteTables"]
        private_rt = self.require_one(
            [
                route_table
                for route_table in route_tables
                if any(tag["Key"] == "Name" and tag["Value"] == f"{self.name_prefix}_private_route_table_0" for tag in route_table.get("Tags", []))
            ],
            f"private route table for {self.name_prefix}",
        )
        public_rt = self.require_one(
            [
                route_table
                for route_table in route_tables
                if any(tag["Key"] == "Name" and tag["Value"] == f"{self.name_prefix}_public_route_table" for tag in route_table.get("Tags", []))
            ],
            f"public route table for {self.name_prefix}",
        )
        self.add("module.gateway_vpc.aws_route_table.private[0]", private_rt["RouteTableId"])
        self.add("module.gateway_vpc.aws_route_table.public", public_rt["RouteTableId"])
        self.skip(
            "module.gateway_vpc.aws_route.private_nat_gateway[0]",
            "Import can return empty-result provider error in this environment; allow Terraform to adopt/manage this route without explicit import.",
        )
        self.add("module.gateway_vpc.aws_route.public_internet_gateway", route_import_id(public_rt["RouteTableId"], "0.0.0.0/0"))

        private_subnet_ids = [
            self.find_subnet(name, "Private")["SubnetId"] for name in subnet_names_private
        ]
        public_subnet_ids = [
            self.find_subnet(name, "Public")["SubnetId"] for name in subnet_names_public
        ]
        for index, subnet_id in enumerate(private_subnet_ids):
            self.add(
                f"module.gateway_vpc.aws_route_table_association.private[{index}]",
                f"{subnet_id}/{private_rt['RouteTableId']}",
            )
        for index, subnet_id in enumerate(public_subnet_ids):
            self.add(
                f"module.gateway_vpc.aws_route_table_association.public[{index}]",
                f"{subnet_id}/{public_rt['RouteTableId']}",
            )

        self.add("module.gateway_vpc.aws_network_acl_rule.block_ssh[0]", nacl_rule_import_id(main_nacl_id, 50, "tcp", False))
        self.add("module.gateway_vpc.aws_network_acl_rule.block_rdp[0]", nacl_rule_import_id(main_nacl_id, 51, "tcp", False))
        self.add("module.gateway_vpc.aws_network_acl_rule.block_ssh_egress[0]", nacl_rule_import_id(main_nacl_id, 52, "tcp", True))
        self.add("module.gateway_vpc.aws_network_acl_rule.block_rdp_egress[0]", nacl_rule_import_id(main_nacl_id, 53, "tcp", True))
        self.add("module.gateway_vpc.aws_network_acl_rule.https_request_egress_443[0]", nacl_rule_import_id(main_nacl_id, 60, "tcp", True))
        self.add("module.gateway_vpc.aws_network_acl_rule.https_request_out_egress_ephemeral[0]", nacl_rule_import_id(main_nacl_id, 61, "tcp", True))
        self.add("module.gateway_vpc.aws_network_acl_rule.https_request_out_response_ingress_443[0]", nacl_rule_import_id(main_nacl_id, 62, "tcp", False))
        self.add("module.gateway_vpc.aws_network_acl_rule.https_request_out_response_ingress_ephemeral[0]", nacl_rule_import_id(main_nacl_id, 63, "tcp", False))
        self.add("module.gateway_vpc.aws_network_acl_rule.https_request_in_ingress_443[0]", nacl_rule_import_id(main_nacl_id, 70, "tcp", False))
        self.add("module.gateway_vpc.aws_network_acl_rule.https_request_in_ingress_ephemeral[0]", nacl_rule_import_id(main_nacl_id, 71, "tcp", False))
        self.add("module.gateway_vpc.aws_network_acl_rule.https_request_in_response_egress_443[0]", nacl_rule_import_id(main_nacl_id, 72, "tcp", True))
        self.add("module.gateway_vpc.aws_network_acl_rule.https_request_in_response_egress_ephemeral[0]", nacl_rule_import_id(main_nacl_id, 73, "tcp", True))

        flow_logs = self.aws.ec2.describe_flow_logs(
            Filters=[{"Name": "resource-id", "Values": [vpc_id]}]
        )["FlowLogs"]
        flow_log = self.require_one(flow_logs, f"VPC flow log for {vpc_id}")
        self.add("module.gateway_vpc.aws_flow_log.flow_logs[0]", flow_log["FlowLogId"])
        self.add("module.gateway_vpc.aws_cloudwatch_log_group.flow_logs[0]", f"{self.name_prefix}_flow_logs")
        self.add("module.gateway_vpc.aws_iam_role.flow_logs[0]", f"{self.name_prefix}_flow_logs")
        flow_logs_policy_name = f"{self.name_prefix}_VpcMetricsFlowLogsWrite"
        flow_logs_policy_arn = self.find_policy_arn(flow_logs_policy_name)
        self.add("module.gateway_vpc.aws_iam_policy.vpc_metrics_flow_logs_write_policy[0]", flow_logs_policy_arn)
        self.add(
            "module.gateway_vpc.aws_iam_role_policy_attachment.vpc_metrics_flow_logs_write_policy_attach[0]",
            role_policy_attachment_import_id(f"{self.name_prefix}_flow_logs", flow_logs_policy_arn),
        )

    def generate_root_network(self, vpc: Dict[str, Any]) -> None:
        vpc_id = vpc["VpcId"]

        vpce_sg = self.find_sg_by_name(vpc_id, f"{self.name_prefix}-vpce-sg")
        ecs_sg = self.find_sg_by_name(vpc_id, f"{self.name_prefix}-litellm-ecs-sg")
        alb_sg = self.find_sg_by_name(vpc_id, f"{self.name_prefix}-litellm-alb-sg")
        redis_sg = self.find_sg_by_name(vpc_id, f"{self.name_prefix}-litellm-redis-sg")
        root_rds_sg = self.find_sg_by_name(vpc_id, f"{self.name_prefix}-litellm-rds-sg")
        module_rds_sg = self.find_sg_by_name(vpc_id, "litellm_rds_sg")

        self.add("aws_security_group.vpce", vpce_sg["GroupId"])
        self.add("aws_security_group.litellm_ecs", ecs_sg["GroupId"])
        self.add("aws_security_group.litellm_alb", alb_sg["GroupId"])
        self.add("aws_security_group.litellm_redis", redis_sg["GroupId"])
        self.add("aws_security_group.litellm_rds", root_rds_sg["GroupId"])

        endpoints = self.aws.ec2.describe_vpc_endpoints(
            Filters=[{"Name": "vpc-id", "Values": [vpc_id]}]
        )["VpcEndpoints"]
        endpoint_by_service = {endpoint["ServiceName"]: endpoint for endpoint in endpoints}
        runtime_service = f"com.amazonaws.{self.region}.bedrock-runtime"
        agent_service = f"com.amazonaws.{self.region}.bedrock-agent-runtime"
        self.add("aws_vpc_endpoint.bedrock_runtime", endpoint_by_service[runtime_service]["VpcEndpointId"])
        self.add("aws_vpc_endpoint.bedrock_agent_runtime", endpoint_by_service[agent_service]["VpcEndpointId"])

        self.add(
            "aws_security_group_rule.litellm_ecs_ingress_from_alb",
            sg_rule_import_id(ecs_sg["GroupId"], "ingress", "tcp", 4000, 4000, alb_sg["GroupId"]),
        )
        self.add(
            "aws_security_group_rule.litellm_ecs_egress_https",
            sg_rule_import_id(ecs_sg["GroupId"], "egress", "tcp", 443, 443, "0.0.0.0/0"),
        )
        self.add(
            "aws_security_group_rule.litellm_ecs_egress_rds",
            sg_rule_import_id(ecs_sg["GroupId"], "egress", "tcp", 5432, 5432, module_rds_sg["GroupId"]),
        )
        self.add(
            "aws_security_group_rule.litellm_ecs_egress_redis",
            sg_rule_import_id(ecs_sg["GroupId"], "egress", "tcp", 6379, 6379, redis_sg["GroupId"]),
        )
        self.add(
            "aws_security_group_rule.litellm_rds_ingress_from_ecs",
            sg_rule_import_id(root_rds_sg["GroupId"], "ingress", "tcp", 5432, 5432, ecs_sg["GroupId"]),
        )
        self.add(
            "aws_security_group_rule.litellm_rds_module_sg_ingress_from_ecs",
            sg_rule_import_id(module_rds_sg["GroupId"], "ingress", "tcp", 5432, 5432, ecs_sg["GroupId"]),
        )
        self.add(
            "aws_security_group_rule.litellm_redis_ingress_from_ecs",
            sg_rule_import_id(redis_sg["GroupId"], "ingress", "tcp", 6379, 6379, ecs_sg["GroupId"]),
        )

        self.add(
            "aws_security_group_rule.litellm_alb_ingress_http",
            sg_rule_import_id(alb_sg["GroupId"], "ingress", "tcp", 80, 80, "0.0.0.0/0"),
        )
        self.add(
            "aws_security_group_rule.litellm_alb_ingress_https",
            sg_rule_import_id(alb_sg["GroupId"], "ingress", "tcp", 443, 443, "0.0.0.0/0"),
        )
        self.add(
            "aws_security_group_rule.litellm_alb_egress_to_ecs",
            sg_rule_import_id(alb_sg["GroupId"], "egress", "tcp", 4000, 4000, ecs_sg["GroupId"]),
        )

        network_acl = self.require_one(
            self.aws.ec2.describe_network_acls(
                Filters=[
                    {"Name": "vpc-id", "Values": [vpc_id]},
                    {"Name": "tag:Name", "Values": [f"{self.name_prefix}_main_nacl"]},
                ]
            )["NetworkAcls"],
            f"network ACL {self.name_prefix}_main_nacl",
        )
        network_acl_id = network_acl["NetworkAclId"]
        for port in self.public_ports:
            self.add(
                f'aws_network_acl_rule.public_listener_inbound["{port}"]',
                nacl_rule_import_id(network_acl_id, self.inputs["listener_nacl_rule_start"] + port, "tcp", False),
            )
            self.add(
                f'aws_network_acl_rule.public_listener_outbound["{port}"]',
                nacl_rule_import_id(network_acl_id, self.inputs["listener_nacl_rule_start"] + 100 + port, "tcp", True),
            )

        fixed_rules = [
            ("aws_network_acl_rule.litellm_http_inbound_4000", 80, False),
            ("aws_network_acl_rule.litellm_http_outbound_4000", 81, True),
            ("aws_network_acl_rule.litellm_postgres_inbound_5432", 82, False),
            ("aws_network_acl_rule.litellm_postgres_outbound_5432", 83, True),
            ("aws_network_acl_rule.litellm_redis_inbound_6379", 84, False),
            ("aws_network_acl_rule.litellm_redis_outbound_6379", 85, True),
        ]
        for address, rule_number, egress in fixed_rules:
            self.add(address, nacl_rule_import_id(network_acl_id, rule_number, "tcp", egress))

    def generate_dns_and_alb(self, vpc: Dict[str, Any]) -> None:
        lb = self.find_lb()
        tg = self.find_tg()
        self.add("aws_lb.litellm", lb["LoadBalancerArn"])
        self.add("aws_lb_target_group.litellm", tg["TargetGroupArn"])
        self.add("aws_lb_listener.litellm_http_redirect", self.find_lb_listener(lb["LoadBalancerArn"], 80)["ListenerArn"])
        self.add("aws_lb_listener.litellm_https", self.find_lb_listener(lb["LoadBalancerArn"], 443)["ListenerArn"])

        zone = self.find_hosted_zone()
        zone_id = zone["CleanId"]
        self.add("aws_route53_zone.gateway", zone_id)
        self.add("aws_route53_record.gateway_alias_a[0]", route53_record_import_id(zone_id, self.gateway_domain_name, "A"))
        self.add("aws_route53_record.gateway_alias_aaaa[0]", route53_record_import_id(zone_id, self.gateway_domain_name, "AAAA"))

        certificate_arn = self.inputs.get("gateway_certificate_arn", "")
        if not certificate_arn:
            paginator = self.aws.acm.get_paginator("list_certificates")
            cert_arn = None
            for page in paginator.paginate(CertificateStatuses=["ISSUED", "PENDING_VALIDATION", "INACTIVE", "EXPIRED"]):
                for summary in page["CertificateSummaryList"]:
                    if summary["DomainName"] == self.gateway_domain_name:
                        cert_arn = summary["CertificateArn"]
                        break
                if cert_arn:
                    break
            if cert_arn is None:
                raise ImportGeneratorError(f"Unable to find ACM certificate for {self.gateway_domain_name}.")

            certificate = self.aws.acm.describe_certificate(CertificateArn=cert_arn)["Certificate"]
            self.add("aws_acm_certificate.gateway[0]", cert_arn)

            for domain_validation in certificate.get("DomainValidationOptions", []):
                domain_name = domain_validation["DomainName"]
                record = domain_validation.get("ResourceRecord")
                if not record:
                    continue
                self.add(
                    f'aws_route53_record.gateway_certificate_validation["{domain_name}"]',
                    route53_record_import_id(zone_id, record["Name"], record["Type"]),
                )

            self.skip(
                "aws_acm_certificate_validation.gateway[0]",
                "Terraform treats certificate validation as a workflow waiter, not a stable AWS object to import.",
            )
        else:
            self.skip(
                "aws_acm_certificate.gateway[0]",
                "gateway_certificate_arn is already set externally, so the certificate resource is not instantiated.",
            )

    def generate_logging_and_storage(self, vpc: Dict[str, Any]) -> None:
        invocation_bucket = f"{self.name_prefix}-{self.account_id}-{self.region}-invocation-logs"
        alb_bucket = f"{self.name_prefix}-{self.account_id}-{self.region}-alb-access-logs"

        self.add("module.invocation_logs_bucket.aws_s3_bucket.this", invocation_bucket)
        self.add("module.invocation_logs_bucket.aws_s3_bucket_public_access_block.this", invocation_bucket)
        self.add("module.alb_access_logs_bucket.aws_s3_bucket.this", alb_bucket)
        self.add("module.alb_access_logs_bucket.aws_s3_bucket_public_access_block.this", alb_bucket)

        alias = self.find_kms_alias(f"alias/{self.name_prefix}-invocation-logs")
        self.add("aws_kms_alias.invocation_logs", alias["AliasName"])
        self.add("aws_kms_key.invocation_logs", alias["TargetKeyId"])

        self.add("aws_cloudwatch_log_group.invocation", f"/aws/bedrock/{self.name_prefix}/invocations")
        self.add("aws_cloudwatch_log_group.guardrail_events", f"/aws/bedrock/{self.name_prefix}/guardrail-events")
        self.skip(
            "aws_bedrock_model_invocation_logging_configuration.this",
            "Import often returns empty result when account-level Bedrock logging config is absent or not yet readable; allow Terraform to create/manage it.",
        )
        self.add(
            "aws_cloudtrail.bedrock_audit",
            f"arn:aws:cloudtrail:{self.region}:{self.account_id}:trail/{self.name_prefix}-bedrock-audit",
        )
        self.add("aws_s3_bucket_policy.invocation_logs", invocation_bucket)
        self.add("aws_s3_bucket_policy.alb_access_logs", alb_bucket)
        self.add("aws_s3_object.litellm_config", f"{invocation_bucket}/{self.inputs['litellm_config_s3_key']}")

    def generate_iam(self, vpc: Dict[str, Any]) -> None:
        self.add("aws_iam_role.bedrock_logging", f"{self.name_prefix}-bedrock-logging-role")
        self.add(
            "aws_iam_role_policy.bedrock_logging",
            role_policy_import_id(f"{self.name_prefix}-bedrock-logging-role", f"{self.name_prefix}-bedrock-logging-policy"),
        )
        self.add("aws_iam_role.bedrock_consumer_team_alpha", "BedrockConsumer-team-alpha")
        self.add(
            "aws_iam_role_policy.bedrock_consumer_team_alpha",
            role_policy_import_id("BedrockConsumer-team-alpha", "BedrockConsumer-team-alpha-policy"),
        )
        self.add(
            "aws_iam_policy.assume_bedrock_consumer_team_alpha",
            self.find_policy_arn(f"{self.name_prefix}-assume-bedrock-consumer-team-alpha"),
        )
        self.add("aws_iam_role.litellm_task", "BedrockConsumer-litellm")
        self.add(
            "aws_iam_role_policy.litellm_task",
            role_policy_import_id("BedrockConsumer-litellm", "BedrockConsumer-litellm-policy"),
        )

    def generate_secrets_and_redis(self, vpc: Dict[str, Any]) -> None:
        secret_names = {
            "aws_secretsmanager_secret.litellm_master_key": f"{self.name_prefix}/litellm/master-key",
            "aws_secretsmanager_secret.litellm_db_password": f"{self.name_prefix}/litellm/db-password",
            "aws_secretsmanager_secret.litellm_redis_auth_token": f"{self.name_prefix}/litellm/redis-auth-token",
        }
        for address, secret_name in secret_names.items():
            secret = self.find_secret(secret_name)
            self.add(address, secret["ARN"])
            current = self.aws.secretsmanager.get_secret_value(SecretId=secret["ARN"], VersionStage="AWSCURRENT")
            version_address = address.replace("aws_secretsmanager_secret.", "aws_secretsmanager_secret_version.")
            self.add(version_address, f"{secret['ARN']}|{current['VersionId']}")

        subnet_group_name = f"{self.name_prefix}-litellm-redis"
        self.add("aws_elasticache_subnet_group.litellm", subnet_group_name)
        self.add("aws_elasticache_replication_group.litellm", f"{self.name_prefix}-litellm-redis")

    def generate_rds(self, vpc: Dict[str, Any]) -> None:
        cluster_identifier = "litellm-cluster"
        cluster = self.aws.rds.describe_db_clusters(DBClusterIdentifier=cluster_identifier)["DBClusters"][0]
        self.add("module.litellm_rds.aws_rds_cluster.cluster", cluster_identifier)
        self.add("module.litellm_rds.aws_db_subnet_group.rds", "litellm-subnet-group")
        self.add("module.litellm_rds.aws_cloudwatch_log_group.log_exports[\"postgresql\"]", f"/aws/rds/cluster/{cluster_identifier}/postgresql")

        for index in range(int(self.inputs["litellm_rds_instances"])):
            instance_id = f"litellm-instance-{index}"
            self.add(f"module.litellm_rds.aws_rds_cluster_instance.instances[{index}]", instance_id)

        module_rds_sg = self.find_sg_by_name(vpc["VpcId"], "litellm_rds_sg")
        self.add("module.litellm_rds.aws_security_group.rds", module_rds_sg["GroupId"])
        self.add(
            "module.litellm_rds.aws_security_group_rule.rds_ingress",
            sg_rule_import_id(module_rds_sg["GroupId"], "ingress", "tcp", 5432, 5432, "self"),
        )
        self.add(
            "module.litellm_rds.aws_security_group_rule.rds_egress",
            sg_rule_import_id(module_rds_sg["GroupId"], "egress", "tcp", 5432, 5432, "self"),
        )

        self.skip("module.litellm_rds.aws_db_proxy.proxy[0]", "The current configuration sets use_proxy = false, so proxy resources are not instantiated.")
        self.skip("module.litellm_rds.aws_db_proxy_default_target_group.this[0]", "The current configuration sets use_proxy = false, so proxy resources are not instantiated.")
        self.skip("module.litellm_rds.aws_db_proxy_target.target[0]", "The current configuration sets use_proxy = false, so proxy resources are not instantiated.")
        self.skip("module.litellm_rds.aws_cloudwatch_log_group.proxy[0]", "The current configuration sets use_proxy = false, so proxy resources are not instantiated.")
        self.skip("module.litellm_rds.aws_iam_role.rds_proxy[0]", "The current configuration sets use_proxy = false, so proxy resources are not instantiated.")
        self.skip("module.litellm_rds.aws_iam_policy.read_connection_string[0]", "The current configuration sets use_proxy = false, so proxy resources are not instantiated.")
        self.skip("module.litellm_rds.aws_iam_role_policy_attachment.read_connection_string[0]", "The current configuration sets use_proxy = false, so proxy resources are not instantiated.")
        self.skip("module.litellm_rds.aws_secretsmanager_secret.connection_string[0]", "The current configuration sets use_proxy = false, so proxy resources are not instantiated.")
        self.skip("module.litellm_rds.aws_secretsmanager_secret_version.connection_string[0]", "The current configuration sets use_proxy = false, so proxy resources are not instantiated.")
        self.skip("module.litellm_rds.aws_secretsmanager_secret.proxy_connection_string[0]", "The current configuration sets use_proxy = false, so proxy resources are not instantiated.")
        self.skip("module.litellm_rds.aws_secretsmanager_secret_version.proxy_connection_string[0]", "The current configuration sets use_proxy = false, so proxy resources are not instantiated.")
        self.skip("module.litellm_rds.aws_db_event_subscription.rds_sg_events_alerts[0]", "The current configuration leaves security_group_notifications_topic_arn empty, so the event subscription is not instantiated.")

    def generate_ecs(self, vpc: Dict[str, Any]) -> None:
        cluster_name = f"{self.name_prefix}-litellm"
        service_name = "litellm"
        service = self.find_ecs_service(cluster_name, service_name)
        task_definition_arn = service["taskDefinition"]

        self.add("module.litellm.aws_ecs_cluster.this[0]", cluster_name)
        self.add("module.litellm.aws_ecs_cluster_capacity_providers.this[0]", cluster_name)
        self.add("module.litellm.aws_ecs_service.this[0]", ecs_service_import_id(cluster_name, service_name))
        self.add("module.litellm.aws_ecs_task_definition.this", task_definition_arn)
        self.add("module.litellm.aws_cloudwatch_log_group.this", f"/aws/ecs/{cluster_name}/{service_name}")

        exec_role_name = f"{service_name}_ecs_task_exec_role"
        exec_policy_name = f"{service_name}_ecs_task_exec_policy"
        exec_policy_arn = self.find_policy_arn(exec_policy_name)
        self.add("module.litellm.aws_iam_role.this_task_exec", exec_role_name)
        self.add("module.litellm.aws_iam_policy.this_task_exec", exec_policy_arn)
        self.add(
            "module.litellm.aws_iam_role_policy_attachment.this_task_exec",
            role_policy_attachment_import_id(exec_role_name, exec_policy_arn),
        )

        resource_id = f"service/{cluster_name}/{service_name}"
        self.add(
            "module.litellm.aws_appautoscaling_target.this[0]",
            appscaling_target_import_id("ecs", resource_id, "ecs:service:DesiredCount"),
        )

        cpu_policy = self.find_autoscaling_policy(resource_id, "cpu")
        memory_policy = self.find_autoscaling_policy(resource_id, "memory")
        self.add(
            'module.litellm.aws_appautoscaling_policy.this["cpu"]',
            appscaling_policy_import_id("ecs", resource_id, "ecs:service:DesiredCount", cpu_policy["PolicyName"]),
        )
        self.add(
            'module.litellm.aws_appautoscaling_policy.this["memory"]',
            appscaling_policy_import_id("ecs", resource_id, "ecs:service:DesiredCount", memory_policy["PolicyName"]),
        )

        self.skip("module.litellm.aws_ssm_parameter.container_image_deployed[0]", "container_image_track_deployed defaults to false, so the SSM parameter is not instantiated.")
        self.skip("module.litellm.aws_iam_role.this_task", "The root module passes task_role_arn, so the ECS module does not create its own task role.")
        self.skip("module.litellm.aws_iam_policy.this_task[0]", "The root module passes task_role_arn and no task_role_policy_documents, so the ECS module does not create this policy.")
        self.skip("module.litellm.aws_iam_role_policy_attachment.this_task[0]", "The root module passes task_role_arn and no task_role_policy_documents, so the ECS module does not create this attachment.")
        self.skip("module.litellm.aws_cloudwatch_log_group.this_service_connect[0]", "service_connect_enabled defaults to false, so the service connect log group is not instantiated.")
        self.skip("module.litellm.aws_cloudwatch_log_subscription_filter.this_sentinel_forwarder[0]", "sentinel_forwarder defaults to false, so the log subscription is not instantiated.")
        self.skip("module.litellm.aws_service_discovery_service.this[0]", "service_discovery_enabled defaults to false, so service discovery is not instantiated.")


def parse_args(argv: Sequence[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Generate Terraform import blocks for the terragrunt/ai_gateway stack."
    )
    parser.add_argument(
        "--stack-dir",
        type=Path,
        default=DEFAULT_STACK_DIR,
        help=f"Terragrunt stack directory. Defaults to {DEFAULT_STACK_DIR}.",
    )
    parser.add_argument(
        "--output",
        type=Path,
        default=DEFAULT_OUTPUT,
        help=f"Path to write generated import blocks. Defaults to {DEFAULT_OUTPUT}.",
    )
    parser.add_argument(
        "--report",
        type=Path,
        default=DEFAULT_REPORT,
        help=f"Path to write generation report JSON. Defaults to {DEFAULT_REPORT}.",
    )
    parser.add_argument(
        "--profile",
        help="Optional AWS CLI profile to use for discovery calls.",
    )
    return parser.parse_args(list(argv))


def main(argv: Sequence[str]) -> int:
    args = parse_args(argv)
    stack_dir = args.stack_dir.resolve()
    if not stack_dir.exists():
        raise ImportGeneratorError(f"Stack directory does not exist: {stack_dir}")

    rendered = terragrunt_render(stack_dir)
    module_manifest_path = ensure_module_manifest(stack_dir)
    module_manifest = json.loads(module_manifest_path.read_text(encoding="utf-8"))
    region = rendered["inputs"]["primary_region"]

    aws = AwsFacade(region, profile=args.profile)
    generator = Generator(stack_dir, aws, rendered, module_manifest)
    imports, skipped = generator.generate()

    existing_addresses = terragrunt_state_list(stack_dir)
    already_imported = [block.address for block in imports if block.address in existing_addresses]
    imports = [block for block in imports if block.address not in existing_addresses]

    args.output.write_text(render_import_file(imports), encoding="utf-8")
    write_json(
        args.report,
        {
            "account_id": generator.account_id,
            "region": region,
            "stack_dir": str(stack_dir),
            "output": str(args.output),
            "import_count": len(imports),
            "already_imported_count": len(already_imported),
            "already_imported": already_imported,
            "skipped": skipped,
        },
    )

    print(f"Wrote {len(imports)} import blocks to {args.output}")
    if already_imported:
        print(f"Excluded {len(already_imported)} resources already present in state")
    if skipped:
        print(f"Recorded {len(skipped)} skipped resources in {args.report}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main(sys.argv[1:]))
    except ImportGeneratorError as exc:
        print(f"error: {exc}", file=sys.stderr)
        raise SystemExit(1)