output "resource_group" {
  value = azurerm_resource_group.this.name
}

output "aks_cluster" {
  value = azurerm_kubernetes_cluster.this.name
}

output "acr_name" {
  value = azurerm_container_registry.this.name
}

output "acr_login_server" {
  value = azurerm_container_registry.this.login_server
}

output "public_ip" {
  value = azurerm_public_ip.app.ip_address
}

output "public_fqdn" {
  value = azurerm_public_ip.app.fqdn
}

# Values for the GitHub "poc" environment variables. None of them is a secret.
output "github_variables" {
  value = {
    AZURE_CLIENT_ID       = azurerm_user_assigned_identity.ci.client_id
    AZURE_TENANT_ID       = data.azurerm_client_config.current.tenant_id
    AZURE_SUBSCRIPTION_ID = data.azurerm_client_config.current.subscription_id
    ACR_NAME              = azurerm_container_registry.this.name
    AKS_RESOURCE_GROUP    = azurerm_resource_group.this.name
    AKS_CLUSTER           = azurerm_kubernetes_cluster.this.name
  }
}
