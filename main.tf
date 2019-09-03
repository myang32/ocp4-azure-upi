locals {
  master_subnet_cidr = "${cidrsubnet(var.machine_cidr, 3, 2)}" #master subnet is a smaller subnet within the vnet. i.e from /21 to /24
  node_subnet_cidr   = "${cidrsubnet(var.machine_cidr, 3, 1)}" #node subnet is a smaller subnet within the vnet. i.e from /21 to /24
  cluster_nr = "${split("-", "${var.cluster_id}")[length(split("-", "${var.cluster_id}")) - 1]}"
  cluster_domain = "${replace(var.cluster_id, "-${local.cluster_nr}", "")}.${var.base_domain}"
}

provider "azurerm" {
  subscription_id = "${var.azure_subscription_id}"
  client_id       = "${var.azure_client_id}"
  client_secret   = "${var.azure_client_secret}"
  tenant_id       = "${var.azure_tenant_id}"
  version         = "=1.32"
}

data "azurerm_subscription" "current" {
}

module "bootstrap" {
  source                  = "./bootstrap"
  resource_group_name = "${azurerm_resource_group.main.name}"
  region                  = "${var.azure_region}"
  vm_size                 = "${var.azure_bootstrap_vm_type}"
  vm_image                = "${var.azure_image_id}"
  identity                = "${azurerm_user_assigned_identity.main.id}"
  cluster_id              = "${var.cluster_id}"
  subnet_id               = "${module.vnet.master_subnet_ids}"
  ignition                = "${data.ignition_config.bootstrap_redirect.rendered}"
  ilb_backend_pool_id     = "${module.vnet.internal_lb_backend_pool_id}"
  boot_diag_blob_endpoint = "${azurerm_storage_account.bootdiag.primary_blob_endpoint}"
  nsg_name                = "${module.vnet.master_nsg_name}"

  # This is to create explicit dependency on private zone to exist before VMs are created in the vnet. https://github.com/MicrosoftDocs/azure-docs/issues/13728
  private_dns_zone_id = "${azurerm_dns_zone.private.id}"
}

module "vnet" {
  source              = "./vnet"
  vnet_name           = "${azurerm_virtual_network.cluster_vnet.name}"
  resource_group_name = "${azurerm_resource_group.main.name}"
  master_subnet_cidr  = "${local.master_subnet_cidr}"
  node_subnet_cidr    = "${local.node_subnet_cidr}"
  cluster_id          = "${var.cluster_id}"
  region              = "${var.azure_region}"
  dns_label           = "${var.cluster_id}"

  # This is to create explicit dependency on private zone to exist before VMs are created in the vnet. https://github.com/MicrosoftDocs/azure-docs/issues/13728
  private_dns_zone_id = "${azurerm_dns_zone.private.id}"
}

module "master" {
  source                  = "./master"
  resource_group_name = "${azurerm_resource_group.main.name}"
  cluster_id              = "${var.cluster_id}"
  region                  = "${var.azure_region}"
  vm_size                 = "${var.azure_master_vm_type}"
  vm_image                = "${var.azure_image_id}"
  identity                = "${azurerm_user_assigned_identity.main.id}"
  ignition                = "${data.ignition_config.master_redirect.rendered}"
  ilb_backend_pool_id     = "${module.vnet.internal_lb_backend_pool_id}"
  master_subnet_cidr      = "${local.master_subnet_cidr}"
  subnet_id               = "${module.vnet.master_subnet_ids}"
  instance_count          = "${var.master_count}"
  boot_diag_blob_endpoint = "${azurerm_storage_account.bootdiag.primary_blob_endpoint}"
  os_volume_size          = "${var.azure_master_root_volume_size}"
  #availability_set_id    = "${azurerm_availability_set.control-plane.id}"

  # This is to create explicit dependency on private zone to exist before VMs are created in the vnet. https://github.com/MicrosoftDocs/azure-docs/issues/13728
  private_dns_zone_id = "${azurerm_dns_zone.private.id}"
}

module "dns" {
  source                          = "./dns"
  internal_lb_ipaddress           = "${module.vnet.internal_lb_ip_address}"
  resource_group_name             = "${azurerm_resource_group.main.name}"
  private_dns_zone_name           = "${local.cluster_domain}"
  etcd_count                      = "${var.master_count}"
  etcd_ip_addresses               = "${module.master.ip_addresses}"
  #ip_address                      = "${module.bootstrap.ip_address}"
  private_dns_zone_id = "${azurerm_dns_zone.private.id}"
}

resource "azurerm_resource_group" "main" {
  name     = "${var.cluster_id}-rg"
  location = "${var.azure_region}"
}

resource "azurerm_storage_account" "bootdiag" {
  name                     = "bootdiag${local.cluster_nr}"
  resource_group_name      = "${azurerm_resource_group.main.name}"
  location                 = "${var.azure_region}"
  account_tier             = "Standard"
  account_replication_type = "LRS"
}

resource "azurerm_user_assigned_identity" "main" {
  name                = "identity${local.cluster_nr}"
  resource_group_name = "${azurerm_resource_group.main.name}"
  location            = "${var.azure_region}"
}

resource "azurerm_role_assignment" "main" {
  scope                = "${data.azurerm_subscription.current.id}/resourcegroups/${var.cluster_id}-rg"
  role_definition_name = "Contributor"
  principal_id         = "${azurerm_user_assigned_identity.main.principal_id}"
}

resource "azurerm_virtual_network" "cluster_vnet" {
  name                = "${var.cluster_id}-vnet"
  resource_group_name = "${azurerm_resource_group.main.name}"
  location            = "${var.azure_region}"
  address_space       = ["${var.machine_cidr}"]
}

resource "azurerm_virtual_network_peering" "test1" {
  name                      = "common"
  resource_group_name       = "${azurerm_resource_group.main.name}"
  virtual_network_name      = "${azurerm_virtual_network.cluster_vnet.name}"
  remote_virtual_network_id = "${data.azurerm_subscription.current.id}/resourceGroups/${var.common_group}/providers/Microsoft.Network/virtualNetworks/${var.vnet_name}"
  allow_virtual_network_access = true
  allow_forwarded_traffic      = true
  use_remote_gateways          = true
}

resource "azurerm_virtual_network_peering" "test2" {
  name                      = "ocp"
  resource_group_name       = "${var.common_group}"
  virtual_network_name      = "${var.vnet_name}"
  remote_virtual_network_id = "${azurerm_virtual_network.cluster_vnet.id}"
  allow_virtual_network_access = true
  allow_forwarded_traffic      = true
  allow_gateway_transit        = true
}

# https://github.com/MicrosoftDocs/azure-docs/issues/13728
resource "azurerm_dns_zone" "private" {
  name                           = "${local.cluster_domain}"
  resource_group_name            = "${azurerm_resource_group.main.name}"
  zone_type                      = "Private"
  resolution_virtual_network_ids = ["${azurerm_virtual_network.cluster_vnet.id}"]
}

resource "azurerm_storage_account" "ignition" {
  name                     = "ignition${local.cluster_nr}"
  resource_group_name      = "${azurerm_resource_group.main.name}"
  location                 = "${var.azure_region}"
  account_tier             = "Standard"
  account_replication_type = "LRS"
}

data "azurerm_storage_account_sas" "ignition" {
  connection_string = "${azurerm_storage_account.ignition.primary_connection_string}"
  https_only        = true

  resource_types {
    service   = false
    container = false
    object    = true
  }

  services {
    blob  = true
    queue = false
    table = false
    file  = false
  }

  start  = timestamp()

  expiry = timeadd(timestamp(), "24h")

  permissions {
    read    = true
    list    = true
    create  = false
    add     = false
    delete  = false
    process = false
    write   = false
    update  = false
  }
}

resource "azurerm_storage_container" "ignition" {
  resource_group_name   = "${azurerm_resource_group.main.name}"
  name                  = "ignition"
  storage_account_name  = "${azurerm_storage_account.ignition.name}"
  container_access_type = "private"
}

resource "azurerm_storage_blob" "ignition-bootstrap" {
  name                   = "bootstrap.ign"
  source                 = "ignition-files/bootstrap.ign"
  resource_group_name    = "${azurerm_resource_group.main.name}"
  storage_account_name   = "${azurerm_storage_account.ignition.name}"
  storage_container_name = "${azurerm_storage_container.ignition.name}"
  type                   = "block"
}

resource "azurerm_storage_blob" "ignition-master" {
  name                   = "master.ign"
  source                 = "ignition-files/master.ign"
  resource_group_name    = "${azurerm_resource_group.main.name}"
  storage_account_name   = "${azurerm_storage_account.ignition.name}"
  storage_container_name = "${azurerm_storage_container.ignition.name}"
  type                   = "block"
}

data "ignition_config" "master_redirect" {
  replace {
    source = "${azurerm_storage_blob.ignition-master.url}${data.azurerm_storage_account_sas.ignition.sas}"
  }
}

data "ignition_config" "bootstrap_redirect" {
  replace {
    source = "${azurerm_storage_blob.ignition-bootstrap.url}${data.azurerm_storage_account_sas.ignition.sas}"
  }
}

resource "azurerm_storage_blob" "ignition-worker" {
  name                   = "worker.ign"
  source                 = "ignition-files/worker.ign"
  resource_group_name    = "${azurerm_resource_group.main.name}"
  storage_account_name   = "${azurerm_storage_account.ignition.name}"
  storage_container_name = "${azurerm_storage_container.ignition.name}"
  type                   = "block"
}


data "ignition_config" "worker_redirect" {
  replace {
    source = "${azurerm_storage_blob.ignition-worker.url}${data.azurerm_storage_account_sas.ignition.sas}"
  }
}


