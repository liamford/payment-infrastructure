
terraform {

  backend "remote" {
    hostname     = "app.terraform.io"
    organization = "liam_org"

    workspaces {
      name = "payment-infrastructure"
    }
  }
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.47.0"
    }
  }
}

provider "aws" {
  region = var.region
}


variable "cluster_name" {
  default = "payments"
}

variable "cluster_version" {
  default = "1.31"
}

