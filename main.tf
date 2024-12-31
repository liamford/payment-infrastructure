provider "aws" {
  region = var.region
}

# Filter out local zones, which are not currently supported
# with managed node groups
data "aws_availability_zones" "available" {
  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

locals {
  cluster_name = "payment-cluster"
}



module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "5.8.1"
  name = "payments-vpc"
  azs  = slice(data.aws_availability_zones.available.names, 0, 3)
  cidr            = var.vpc_cidr
  private_subnets = var.private_subnets
  public_subnets  = var.public_subnets

  enable_nat_gateway   = true
  single_nat_gateway   = true
  enable_dns_hostnames = true
  enable_dns_support   = true
  one_nat_gateway_per_az = false

  tags = {
    "kubernetes.io/cluster/${local.cluster_name}" = "shared"
  }

  public_subnet_tags = {
    "kubernetes.io/role/elb"                      = 1
    "kubernetes.io/cluster/${local.cluster_name}" = "shared"
  }

  private_subnet_tags = {
    "kubernetes.io/role/internal-elb"             = 1
    "kubernetes.io/cluster/${local.cluster_name}" = "shared"
  }
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "20.8.5"

  cluster_name    = local.cluster_name
  cluster_version = "1.31"

  cluster_endpoint_public_access           = true
  enable_cluster_creator_admin_permissions = true

  cluster_addons = {
    aws-ebs-csi-driver = {
      service_account_role_arn = module.irsa-ebs-csi.iam_role_arn
    }
  }

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  eks_managed_node_group_defaults = {
    ami_type = "AL2_x86_64"

  }

  eks_managed_node_groups = {
    one = {
      name = "node-group-1"

      instance_types = ["t3.small"]

      min_size     = 1
      max_size     = 3
      desired_size = 2
    }

    two = {
      name = "node-group-2"

      instance_types = ["t3.small"]

      min_size     = 1
      max_size     = 2
      desired_size = 1
    }
  }
}


# https://aws.amazon.com/blogs/containers/amazon-ebs-csi-driver-is-now-generally-available-in-amazon-eks-add-ons/
data "aws_iam_policy" "ebs_csi_policy" {
  arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

module "irsa-ebs-csi" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-assumable-role-with-oidc"
  version = "5.39.0"

  create_role                   = true
  role_name                     = "AmazonEKSTFEBSCSIRole-${module.eks.cluster_name}"
  provider_url                  = module.eks.oidc_provider
  role_policy_arns              = [data.aws_iam_policy.ebs_csi_policy.arn]
  oidc_fully_qualified_subjects = ["system:serviceaccount:kube-system:ebs-csi-controller-sa"]
}

data "aws_eks_cluster" "eks" {
  name = module.eks.cluster_name
  depends_on = [module.eks]
}

data "aws_eks_cluster_auth" "eks" {
  name = module.eks.cluster_name
  depends_on = [module.eks]
}

provider "kubernetes" {
  host                   = data.aws_eks_cluster.eks.endpoint
  cluster_ca_certificate = base64decode(data.aws_eks_cluster.eks.certificate_authority[0].data)
  token                  = data.aws_eks_cluster_auth.eks.token
}

resource "kubernetes_namespace" "frontdoor-ns" {
  metadata {
    name = "frontdoor-ns"
  }

  depends_on = [module.eks]
}


resource "kubernetes_service_account" "frontdoor-service-account" {
  metadata {
    name      = "frontdoor-service-account"
    namespace = kubernetes_namespace.frontdoor-ns.metadata[0].name
    annotations = {
      "eks.amazonaws.com/role-arn" = module.irsa-ebs-csi.iam_role_arn
    }
  }
  automount_service_account_token = true
  depends_on = [kubernetes_namespace.frontdoor-ns]
}

resource "kubernetes_service" "frontdoor-service" {
  metadata {
    name = "frontdoor-service"
    namespace = kubernetes_namespace.frontdoor-ns.metadata[0].name
    annotations = {
      "service.beta.kubernetes.io/aws-load-balancer-name" = "frontdoor-service"
      "service.beta.kubernetes.io/aws-load-balancer-type" = "nlb"
      "service.beta.kubernetes.io/aws-load-balancer-internal" = "true"
    }
  }
  spec {
    selector = {
      app = "frontdoor"
    }
    port {
      port        = 80
      protocol = "TCP"
      target_port = 8080
    }
    type = "LoadBalancer"
  }
  depends_on = [module.eks]
}


resource "kubernetes_cluster_role" "all_resources" {
  metadata {
    name = "all-resources"
  }

  rule {
    api_groups = ["*"]
    resources  = ["*"]
    verbs      = ["*"]
  }
}

resource "kubernetes_cluster_role_binding" "all_resources_binding" {
  metadata {
    name = "all-resources-binding"
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = kubernetes_cluster_role.all_resources.metadata[0].name
  }

  subject {
    kind      = "User"
    name      = var.iam_user_arn
    api_group = "rbac.authorization.k8s.io"
  }
}



resource "aws_apigatewayv2_api" "main" {
  name          = "main"
  protocol_type = "HTTP"
}

resource "aws_apigatewayv2_stage" "prod" {
  api_id = aws_apigatewayv2_api.main.id

  name        = "prod"
  auto_deploy = true
}

resource "aws_security_group" "vpc_link" {
  name   = "vpc-link"
  vpc_id = module.vpc.vpc_id

  egress {
    from_port        = 0
    to_port          = 0
    protocol         = "-1"
    cidr_blocks      = ["0.0.0.0/0"]
  }
}

resource "aws_apigatewayv2_vpc_link" "eks" {
  name               = "eks"
  security_group_ids = [aws_security_group.vpc_link.id]
  subnet_ids = [
    module.vpc.private_subnets[0],
    module.vpc.private_subnets[1],
    module.vpc.private_subnets[2]
  ]
}

resource "aws_apigatewayv2_integration" "eks" {
  api_id = aws_apigatewayv2_api.main.id
  integration_uri = "arn:aws:elasticloadbalancing:ap-southeast-2:765874878578:listener/net/aef3c770d2fa84e4f9b192f8356681d9/8d12ee2d55f2d79d/6688639805ad8453"
  integration_type   = "HTTP_PROXY"
  integration_method = "ANY"
  connection_type    = "VPC_LINK"
  connection_id      = aws_apigatewayv2_vpc_link.eks.id
  payload_format_version = "1.0"
}

resource "aws_apigatewayv2_route" "get_health" {
  api_id = aws_apigatewayv2_api.main.id

  route_key = "GET /api/payments/v1/actuator/health"
  target    = "integrations/${aws_apigatewayv2_integration.eks.id}"
}






