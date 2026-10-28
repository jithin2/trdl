terraform {
  required_version = ">= 1.9"

  required_providers {
    azurerm = {
      source = "hashicorp/azurerm"
      # Pinned to 4.x: the code is written against the 4.x schema.
      # Moving to 5.x (July 2026) is a separate, reviewed change.
      version = "~> 4.0"
    }
  }

  # Remote state in Azure Storage with Entra ID auth (no storage keys).
  # Values come from backend.hcl, written by infra/bootstrap/state.sh.
  backend "azurerm" {}
}

provider "azurerm" {
  features {}
  # Subscription comes from ARM_SUBSCRIPTION_ID, so the target is always explicit.
}
