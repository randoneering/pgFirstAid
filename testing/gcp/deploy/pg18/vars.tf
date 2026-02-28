variable "authorized_networks" {
  description = "Authorized networks for Cloud SQL"
  type = list(object({
    name  = string
    value = string
  }))
}
