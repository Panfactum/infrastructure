terraform {
  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "2.22"
    }
    aws = {
      source  = "hashicorp/aws"
      version = "5.10"
    }
  }
}

locals {

  name        = "buildkit"
  namespace   = module.namespace.namespace
  module      = var.module
  environment = var.environment

  labels = merge(var.kube_labels, {
    service = local.name
  })
  match_labels = {
    service = local.name
    module  = local.module
  }

  scale_down_submodule = "buildkit-scaledown"
  scale_down_labels = merge(var.kube_labels, {
    service = local.scale_down_submodule
  })

  port = 1234
}

module "constants" {
  source = "../../modules/constants"
}

/***************************************
* Namespace
***************************************/

module "namespace" {
  source            = "../../modules/kube_namespace"
  namespace         = local.name
  admin_groups      = ["system:admins"]
  reader_groups     = ["system:readers"]
  bot_reader_groups = ["system:bot-readers"]
  kube_labels       = local.labels
}

/***************************************
* S3 Caching Bucket
***************************************/

resource "random_id" "cache_bucket" {
  byte_length = 8
  prefix      = "buildkit-cache-"
}

module "cache_bucket" {
  source             = "../../modules/aws_s3_private_bucket"
  bucket_name        = random_id.cache_bucket.hex
  description        = "Used for buildkit layer caches"
  expire_after_days  = 7
  versioning_enabled = false
}

/***************************************
* AWS Permissions
***************************************/
data "aws_iam_policy_document" "buildkit" {

  // Allowed to control caching bucket
  statement {
    effect  = "Allow"
    actions = ["s3:*"]
    resources = [
      module.cache_bucket.bucket_arn,
      "${module.cache_bucket.bucket_arn}/*"
    ]
  }
}

module "aws_permissions" {
  source                    = "../../modules/kube_sa_auth_aws"
  service_account           = kubernetes_service_account.buildkit.metadata[0].name
  service_account_namespace = local.namespace
  eks_cluster_name          = var.eks_cluster_name
  iam_policy_json           = data.aws_iam_policy_document.buildkit.json
  public_outbound_ips       = var.public_outbound_ips
}

/***************************************
* Buildkit StatefulSet
***************************************/

resource "kubernetes_service_account" "buildkit" {
  metadata {
    name      = local.name
    namespace = local.namespace
    labels    = local.labels
  }
}

resource "kubernetes_stateful_set" "buildkit" {
  metadata {
    name      = local.name
    namespace = local.namespace
    labels    = local.labels
  }
  spec {
    service_name          = local.name
    pod_management_policy = "Parallel"
    replicas              = var.min_replicas
    selector {
      match_labels = local.match_labels
    }
    template {
      metadata {
        labels = local.labels
      }
      spec {
        service_account_name             = kubernetes_service_account.buildkit.metadata[0].name
        termination_grace_period_seconds = 30 * 60

        affinity {
          pod_anti_affinity {
            required_during_scheduling_ignored_during_execution {
              topology_key = "kubernetes.io/hostname"
              label_selector {
                match_labels = local.match_labels
              }
            }
          }
        }

        container {
          name  = "buildkitd"
          image = "moby/buildkit:v0.12.2"
          args = [
            "--addr", "tcp://0.0.0.0:${local.port}",
            "--addr", "unix:///run/buildkit/buildkitd.sock"
          ]

          volume_mount {
            mount_path = "/var/lib/buildkit"
            name       = "buildkitd"
          }

          security_context {
            privileged = true
          }

          port {
            container_port = 1234
            name           = "buildkitd"
            protocol       = "TCP"
          }

          resources {
            requests = {
              cpu    = "${var.cpu_millicores}m"
              memory = "${var.memory_mb}Mi"
            }
            limits = {
              // we set a limit on cpu as the cpu is very
              // bursty for builds and ends up disrupting the other services
              cpu    = "${var.cpu_millicores}m"
              memory = "${var.memory_mb}Mi"
            }
          }

          readiness_probe {
            exec {
              command = ["buildctl", "debug", "workers"]
            }
            initial_delay_seconds = 5
            period_seconds        = 3
          }
          liveness_probe {
            exec {
              command = ["buildctl", "debug", "workers"]
            }
            initial_delay_seconds = 5
            period_seconds        = 30
          }
        }
      }
    }
    volume_claim_template {
      metadata {
        name = "buildkitd"
      }
      spec {
        storage_class_name = "ebs-standard"
        access_modes       = ["ReadWriteOnce"]
        resources {
          requests = {
            storage = "${var.local_storage_gb}Gi"
          }
        }
      }
    }
  }
  wait_for_rollout = false
  lifecycle {
    ignore_changes = [spec[0].replicas]
  }
}

resource "kubernetes_service" "buildkit" {
  metadata {
    name      = local.name
    namespace = local.namespace
    labels    = local.labels
  }
  spec {
    type = "ClusterIP"
    port {
      port        = local.port
      target_port = local.port
      protocol    = "TCP"
      name        = "tcp"
    }
    selector = local.match_labels
  }
}

resource "kubernetes_horizontal_pod_autoscaler_v2" "autoscaler" {
  metadata {
    name      = local.name
    namespace = local.namespace
    labels    = local.labels
  }
  spec {
    scale_target_ref {
      api_version = "apps/v1"
      kind        = "StatefulSet"
      name        = kubernetes_stateful_set.buildkit.metadata[0].name
    }
    min_replicas = var.min_replicas
    max_replicas = var.max_replicas
    metric {
      type = "ContainerResource"
      container_resource {
        name = "memory"
        target {
          type                = "Utilization"
          average_utilization = 70
        }
        container = "buildkitd"
      }
    }
    metric {
      type = "ContainerResource"
      container_resource {
        name = "cpu"
        target {
          type                = "Utilization"
          average_utilization = 70
        }
        container = "buildkitd"
      }
    }
    behavior {
      scale_down {
        select_policy                = "Max"
        stabilization_window_seconds = 300

        policy {
          period_seconds = 60
          type           = "Pods"
          value          = 1
        }
      }

      scale_up {
        select_policy                = "Max"
        stabilization_window_seconds = 60

        policy {
          period_seconds = 15
          type           = "Pods"
          value          = 1
        }
      }
    }
  }
}

resource "kubernetes_manifest" "pdb" {
  manifest = {
    apiVersion = "policy/v1"
    kind       = "PodDisruptionBudget"
    metadata = {
      name      = local.name
      namespace = local.namespace
      labels    = local.labels
    }
    spec = {
      selector = {
        matchLabels = local.match_labels
      }
      maxUnavailable = 0
    }
  }
}
