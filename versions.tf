terraform {
  required_version = ">= 1.6"
  required_providers {
    upcloud = {
      source  = "UpCloudLtd/upcloud"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

# Credentials come from the environment: UPCLOUD_USERNAME / UPCLOUD_PASSWORD (an API subaccount) or UPCLOUD_TOKEN.
provider "upcloud" {}
