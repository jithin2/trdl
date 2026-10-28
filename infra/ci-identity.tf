# Identity used by GitHub Actions. It has no secret: GitHub gets a short-lived
# token through OIDC, and only for jobs in the given repo and environment.

resource "azurerm_user_assigned_identity" "ci" {
  name                = "id-${local.name}-github"
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  tags                = local.tags
}

resource "azurerm_federated_identity_credential" "github_env" {
  name                = "github-${var.github_environment}"
  resource_group_name = azurerm_resource_group.this.name
  parent_id           = azurerm_user_assigned_identity.ci.id
  audience            = ["api://AzureADTokenExchange"]
  issuer              = "https://token.actions.githubusercontent.com"
  subject             = "repo:${var.github_repository}:environment:${var.github_environment}"
}

# Push images.
resource "azurerm_role_assignment" "ci_acr_push" {
  scope                = azurerm_container_registry.this.id
  role_definition_name = "AcrPush"
  principal_id         = azurerm_user_assigned_identity.ci.principal_id
}

# Fetch a (non-admin) kubeconfig.
resource "azurerm_role_assignment" "ci_cluster_user" {
  scope                = azurerm_kubernetes_cluster.this.id
  role_definition_name = "Azure Kubernetes Service Cluster User Role"
  principal_id         = azurerm_user_assigned_identity.ci.principal_id
}

# Write workloads in the app namespace only. No cluster-wide rights.
resource "azurerm_role_assignment" "ci_namespace_writer" {
  scope                = "${azurerm_kubernetes_cluster.this.id}/namespaces/${var.app_namespace}"
  role_definition_name = "Azure Kubernetes Service RBAC Writer"
  principal_id         = azurerm_user_assigned_identity.ci.principal_id
}
