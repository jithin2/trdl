data "azurerm_client_config" "current" {}

locals {
  name = "trdl-${var.environment}"
  # Short, stable suffix for names that must be globally unique.
  suffix = substr(sha1("${data.azurerm_client_config.current.subscription_id}-${local.name}"), 0, 6)
  zones  = ["1", "2", "3"]

  tags = {
    app         = "trdl"
    environment = var.environment
    managed_by  = "terraform"
  }
}

resource "azurerm_resource_group" "this" {
  name     = "rg-${local.name}"
  location = var.location
  tags     = local.tags
}

resource "azurerm_container_registry" "this" {
  name                = "acr${replace(local.name, "-", "")}${local.suffix}"
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  sku                 = "Standard"
  admin_enabled       = false # pull and push with Entra ID identities only
  tags                = local.tags
}

# Static public IP for the TRDL Service. Zone-redundant, so losing one zone
# does not take the address down. It lives outside the AKS node resource
# group, so it survives a cluster rebuild.
resource "azurerm_public_ip" "app" {
  name                = "pip-${local.name}"
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  allocation_method   = "Static"
  sku                 = "Standard"
  zones               = local.zones
  domain_name_label   = "${local.name}-${local.suffix}"
  tags                = local.tags
}
