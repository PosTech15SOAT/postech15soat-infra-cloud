resource "aws_eks_addon" "metrics_server" {
  cluster_name = var.cluster_name
  addon_name   = "metrics-server"
}

resource "helm_release" "datadog" {
  name             = "datadog"
  repository       = "https://helm.datadoghq.com"
  chart            = "datadog"
  version          = "3.242.0"
  namespace        = "datadog"
  create_namespace = true

  values = [
    yamlencode({
      datadog = {
        site        = var.datadog_site
        clusterName = var.cluster_name

        logs = {
          enabled             = true
          containerCollectAll = true
        }

        apm = {
          portEnabled = true
          instrumentation = {
            enabled = false
          }
        }

        dogstatsd = {
          useSocketVolume = false
          useHostPort     = true
          nonLocalTraffic = true
        }

        networkMonitoring = {
          enabled = false
        }

        serviceMonitoring = {
          enabled = false
        }

        otlp = {
          receiver = {
            protocols = {
              grpc = {
                enabled = false
              }
              http = {
                enabled = false
              }
            }
          }
        }

        securityAgent = {
          runtime = {
            enabled = false
          }
          compliance = {
            enabled = false
          }
        }
      }
    })
  ]

  set_sensitive {
    name  = "datadog.apiKey"
    value = var.datadog_api_key
  }
}
