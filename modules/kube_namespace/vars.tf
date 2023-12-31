variable "namespace" {
  description = "The name of the kubernetes namespace to instantiate."
  type        = string
}

variable "linkerd_inject" {
  description = "Whether to inject linkerd sidecars into pods in this namespace."
  type        = bool
  default     = true
}

variable "admin_groups" {
  description = "The names of the kubernetes groups to give admin access to the namespace."
  type        = list(string)
  default     = []
}

variable "reader_groups" {
  description = "The names of the kubernetes groups to give read access to the namespace."
  type        = list(string)
  default     = []
}

variable "bot_reader_groups" {
  description = "The names of the kubernetes groups to give elevated read access to the namespace."
  type        = list(string)
  default     = []
}

variable "kube_labels" {
  description = "The default labels to use for Kubernetes resources"
  type        = map(string)
}
