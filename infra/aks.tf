resource "azurerm_kubernetes_cluster" "this" {
  name                = "aks-${local.name}"
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  dns_prefix          = local.name
  kubernetes_version  = var.kubernetes_version

  # Standard tier gives the API server a financially backed uptime SLA.
  # The Free tier has none, which does not fit a "several nines" goal.
  sku_tier = "Standard"

  # Patch versions and node images are updated by AKS inside the
  # maintenance windows below. Minor versions are a planned change.
  automatic_upgrade_channel = "patch"
  node_os_upgrade_channel   = "NodeImage"

  # Entra ID login and Azure RBAC for Kubernetes. No shared admin kubeconfig.
  local_account_disabled = true
  azure_active_directory_role_based_access_control {
    azure_rbac_enabled = true
    tenant_id          = data.azurerm_client_config.current.tenant_id
  }

  default_node_pool {
    name                        = "system"
    vm_size                     = var.node_vm_size
    os_sku                      = "AzureLinux"
    zones                       = local.zones
    auto_scaling_enabled        = true
    min_count                   = var.node_min_count
    max_count                   = var.node_max_count
    temporary_name_for_rotation = "systemtmp"

    upgrade_settings {
      max_surge = "33%" # one extra node at a time on a 3-node pool
    }
  }

  identity {
    type = "SystemAssigned"
  }

  network_profile {
    network_plugin      = "azure"
    network_plugin_mode = "overlay"
    network_data_plane  = "cilium"
    network_policy      = "cilium" # the chart ships a NetworkPolicy
    load_balancer_sku   = "standard"
  }

  maintenance_window_auto_upgrade {
    frequency   = "Weekly"
    interval    = 1
    duration    = 4
    day_of_week = "Sunday"
    start_time  = "02:00"
    utc_offset  = "+01:00"
  }

  maintenance_window_node_os {
    frequency   = "Weekly"
    interval    = 1
    duration    = 4
    day_of_week = "Saturday"
    start_time  = "02:00"
    utc_offset  = "+01:00"
  }

  tags = local.tags

  lifecycle {
    # The autoscaler owns the live node count.
    ignore_changes = [default_node_pool[0].node_count]
  }
}

# Nodes pull images from ACR with the kubelet identity. No image pull secrets.
resource "azurerm_role_assignment" "kubelet_acr_pull" {
  scope                            = azurerm_container_registry.this.id
  role_definition_name             = "AcrPull"
  principal_id                     = azurerm_kubernetes_cluster.this.kubelet_identity[0].object_id
  skip_service_principal_aad_check = true
}

# The cluster identity must manage the load balancer frontend that uses
# the public IP in our resource group.
resource "azurerm_role_assignment" "cluster_network" {
  scope                = azurerm_resource_group.this.id
  role_definition_name = "Network Contributor"
  principal_id         = azurerm_kubernetes_cluster.this.identity[0].principal_id
}

# Whoever runs Terraform becomes cluster admin, so the setup steps can run.
resource "azurerm_role_assignment" "operator_cluster_admin" {
  scope                = azurerm_kubernetes_cluster.this.id
  role_definition_name = "Azure Kubernetes Service RBAC Cluster Admin"
  principal_id         = data.azurerm_client_config.current.object_id
}
