variable "azure_region" {
  type = "string"
}

variable "azure_worker_root_volume_size" {
type        = "string"
}

variable "azure_worker_vm_type" {
  type = "string"
}

variable "cluster_id" {
  type        = "string"
}

variable "azure_image_id" {
  type        = "string"
}

variable "index" {
  type        = "string"
  description = "New Worker node number (e.g. if last worker node is worker-1, then specify number '2')"
}

variable "azure_subscription_id" {
  type        = "string"
}

variable "azure_client_id" {
  type        = "string"
}

variable "azure_client_secret" {
  type        = "string"
}

variable "azure_tenant_id" {
  type        = "string"
}