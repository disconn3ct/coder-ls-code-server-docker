terraform {
  required_providers {
    coder = {
      source  = "coder/coder"
      version = "~> 0.11.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.22"
    }
  }
}

provider "coder" {
}

variable "namespace" {
  type        = string
  sensitive   = true
  description = "The namespace to create workspaces in (must exist prior to creating workspaces)"
  default     = "coder-workspaces"
  # Forbid powerusers from creating workspaces alongside coder
}

data "coder_parameter" "home_disk_size" {
  type        = "number"
  name        = "Home disk size"
  description = "How large would you like your home volume to be (in GB)?"
  mutable     = false
  default     = 5
  validation {
    min       = 1
    max       = 15
    monotonic = "increasing"
  }
}

data "coder_parameter" "enable_docker" {
  name        = "Enable Docker"
  description = "Enable Docker support? (true/false)"
  type        = "bool"
  mutable     = true
  default     = true
}

data "coder_parameter" "user_shell" {
  name        = "User Shell"
  description = <<-EOF
  The shell for the default user. If it is not part of the standard image, it
  must be installed via extra_package_list.
  EOF
  default     = "/usr/bin/bash"
  type        = "string"
  mutable     = true
}

data "coder_parameter" "dotfiles_uri" {
  mutable     = true
  name        = "Dotfiles URI"
  type        = "string"
  description = <<-EOF
  Dotfiles repo URI (optional)
  see https://dotfiles.github.io

  This will be applied on every workstation start, and may overwrite existing
  files. If you prefer to run it only once, leave this blank and run
  `$HOME/bin/coder dotfiles URL` inside the workspace terminal instead.
  EOF
  default     = ""
}

data "coder_parameter" "extra_package_list" {
  type        = "list(string)"
  mutable     = true
  name        = "Extra Packages"
  description = <<-EOF
  A list of Ubuntu packages to install.

  These packages are installed during every workspace startup and may cause delays
  before the workspace is available.

  EOF
  default     = jsonencode([])
}

data "coder_parameter" "image" {
  type        = "string"
  name        = "Docker Image"
  description = "Docker image"
  mutable     = true
  default     = "ghcr.io/disconn3ct/docker-containers/code-server"
}

data "coder_parameter" "image_version" {
  type        = "string"
  name        = "Docker Image Tag"
  description = "Docker image version"
  mutable     = true
  default     = "main"
}

provider "kubernetes" {
  config_path = null
}

data "coder_workspace" "me" {}

resource "coder_agent" "main" {
  os   = "linux"
  arch = "arm64"
  dir  = "/config/workspace"
  # Runs as `abc` with the user's default shell
  startup_script = data.coder_parameter.dotfiles_uri.value != "" ? "$HOME/bin/coder dotfiles -y ${data.coder_parameter.dotfiles_uri.value}" : null

  env = {
    "CODER_TELEMETRY" = "false"
    # To align with the IDE:
    "PATH"   = "/config/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/config/go/bin:/config/.krew/bin:/config/.local/bin"
    "GOPATH" = "/config/go"
  }

  # The following metadata blocks are optional. They are used to display
  # information about your workspace in the dashboard. You can remove them
  # if you don't want to display any information.
  # For basic resources, you can use the `coder stat` command.
  # If you need more control, you can write your own script.
  metadata {
    display_name = "CPU Usage"
    key          = "0_cpu_usage"
    script       = "$HOME/bin/coder stat cpu"
    interval     = 10
    timeout      = 1
  }

  metadata {
    display_name = "RAM Usage"
    key          = "1_ram_usage"
    script       = "$HOME/bin/coder stat mem"
    interval     = 10
    timeout      = 1
  }

  metadata {
    display_name = "Home Disk"
    key          = "3_home_disk"
    script       = "$HOME/bin/coder stat disk --path $HOME"
    interval     = 60
    timeout      = 1
  }

  metadata {
    display_name = "Load Average (Host)"
    key          = "6_load_host"
    # get load avg scaled by number of cores
    script   = <<EOT
      bash -c 'echo "`cat /proc/loadavg | awk \'{ print $1 }\'` `nproc`" | awk \'{ printf "%0.2f", $1/$2 }\''
    EOT
    interval = 60
    timeout  = 1
  }
}

resource "kubernetes_config_map" "coder-service" {
  metadata {
    generate_name = "coder-${data.coder_workspace.me.id}-svc"
    namespace     = var.namespace
  }
  data = {
    # This trickery is to run the coder agent as `abc`, to align with the web UI.
    "coder-agent.sh"    = <<-EOSVC
      #!/usr/bin/with-contenv bash
      export CODER_AGENT_TOKEN="${coder_agent.main.token}"
      export CODER_TELEMETRY="false"

      export BINARY_DIR=$HOME/bin
      mkdir -pv $BINARY_DIR && chown abc: $BINARY_DIR
      s6-setuidgid abc /custom-services.d/.coder-install.sh
    EOSVC
    ".coder-install.sh" = coder_agent.main.init_script
  }
  immutable = true
}

resource "kubernetes_config_map" "coder-init" {
  metadata {
    generate_name = "coder-${data.coder_workspace.me.id}-init"
    namespace     = var.namespace
  }
  data = {
    "set-shell.sh" = <<-EOSHELL
      #!/bin/bash
      # Required for start-script to work. (Default upstream shell is /bin/false.)
      [ -x "${data.coder_parameter.user_shell.value}" ] && chsh -s "${data.coder_parameter.user_shell.value}" abc
    EOSHELL
  }
  immutable = true
}

# code-server
resource "coder_app" "code-server" {
  agent_id     = coder_agent.main.id
  slug         = "code-server"
  display_name = "VS Code"
  icon         = "/icon/code.svg"
  url          = "http://localhost:8443"
  subdomain    = false
  share        = "owner"

  healthcheck {
    url       = "http://localhost:8443/healthz"
    interval  = 3
    threshold = 10
  }
}

resource "kubernetes_persistent_volume_claim" "home" {
  metadata {
    name      = "coder-${data.coder_workspace.me.id}-home"
    namespace = var.namespace
    labels = {
      "app.kubernetes.io/name"     = "coder-pvc"
      "app.kubernetes.io/instance" = "coder-pvc-${lower(data.coder_workspace.me.owner)}-${lower(data.coder_workspace.me.name)}"
      "app.kubernetes.io/part-of"  = "coder"
      //Coder-specific labels.
      "com.coder.resource"       = "true"
      "com.coder.workspace.id"   = data.coder_workspace.me.id
      "com.coder.workspace.name" = data.coder_workspace.me.name
      "com.coder.user.id"        = data.coder_workspace.me.owner_id
      "com.coder.user.username"  = data.coder_workspace.me.owner
    }
    annotations = {
      "com.coder.user.email" = data.coder_workspace.me.owner_email
    }
  }
  spec {
    access_modes = ["ReadWriteOnce"]
    resources {
      requests = {
        storage = "${data.coder_parameter.home_disk_size.value}Gi"
      }
    }
  }
}

resource "kubernetes_pod" "main" {
  count = data.coder_workspace.me.start_count
  depends_on = [
    kubernetes_persistent_volume_claim.home
  ]
  metadata {
    name      = "coder-${lower(data.coder_workspace.me.owner)}-${lower(data.coder_workspace.me.name)}"
    namespace = var.namespace
    labels = {
      "app.kubernetes.io/name"     = "coder-workspace"
      "app.kubernetes.io/instance" = "coder-workspace-${lower(data.coder_workspace.me.owner)}-${lower(data.coder_workspace.me.name)}"
      "app.kubernetes.io/part-of"  = "coder"
      "com.coder.resource"         = "true"
      "com.coder.workspace.id"     = data.coder_workspace.me.id
      "com.coder.workspace.name"   = data.coder_workspace.me.name
      "com.coder.user.id"          = data.coder_workspace.me.owner_id
      "com.coder.user.username"    = data.coder_workspace.me.owner
    }
    annotations = {
      "com.coder.user.email" = data.coder_workspace.me.owner_email
    }
  }
  spec {
    automount_service_account_token = false
    enable_service_links            = false
    hostname                        = "${data.coder_workspace.me.owner}-${data.coder_workspace.me.name}"
    container {
      name              = "dev"
      image             = "${data.coder_parameter.image.value}:${data.coder_parameter.image_version.value}"
      image_pull_policy = "Always"
      port {
        name           = "http"
        container_port = 8443
      }
      # TODO: Use sysbox or similar to run unprivileged
      security_context {
        privileged = true
      }
      env {
        name  = "PUID"
        value = "1000"
      }
      env {
        name  = "PGID"
        value = "1000"
      }
      # These are LinuxServer addons
      env {
        name  = "DOCKER_MODS"
        value = tobool(data.coder_parameter.enable_docker.value) ? "linuxserver/mods:universal-docker-in-docker|linuxserver/mods:universal-package-install|" : "linuxserver/mods:universal-package-install"
      }
      env {
        name  = "INSTALL_PACKAGES"
        value = join("|", jsondecode(data.coder_parameter.extra_package_list.value))
      }
      env {
        name  = "CODER_TELEMETRY"
        value = "false"
      }
      # Among other things, this forces a new pod on template update
      env {
        name  = "CODER_AGENT_TOKEN"
        value = coder_agent.main.token
      }
      env {
        name  = "CODER_AGENT_AUTH"
        value = "token"
      }
      env {
        name  = "CODER"
        value = "true"
      }
      # copied from a cheat in start-script
      #env {
      #  name  = "GIT_SSH_COMMAND"
      #  value = "$HOME/bin/coder gitssh --"
      #}
      env {
        name  = "SSH_CONNECTION"
        value = "0.0.0.0 0 0.0.0.0 0"
      }
      env {
        name  = "SSH_CLIENT"
        value = "0.0.0.0 0 0"
      }
      # LinuxServer convenience
      env {
        name  = "TZ"
        value = "America/New_York"
      }
      env {
        name  = "PATH"
        value = "/config/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/config/go/bin:/config/.krew/bin:/config/.local/bin"
      }
      env {
        name  = "GOPATH"
        value = "/config/go"
      }

      resources {
        requests = {
          cpu    = "10m"
          memory = "450Mi"
        }
        limits = {
          cpu    = "1500m"
          memory = "2Gi"
        }
      }

      volume_mount {
        mount_path = "/config"
        name       = "home"
        read_only  = false
      }

      volume_mount {
        mount_path = "/custom-services.d"
        name       = "coder-service"
        read_only  = true
      }

      volume_mount {
        mount_path = "/custom-cont-init.d"
        name       = "coder-init"
        read_only  = true
      }
    }

    volume {
      name = "home"
      persistent_volume_claim {
        claim_name = kubernetes_persistent_volume_claim.home.metadata.0.name
        read_only  = false
      }
    }

    # Coder agent service
    volume {
      name = "coder-service"
      config_map {
        name         = kubernetes_config_map.coder-service.metadata.0.name
        default_mode = "0555"
      }
    }
    volume {
      name = "coder-init"
      config_map {
        name         = kubernetes_config_map.coder-init.metadata.0.name
        default_mode = "0555"
      }
    }
  }
}
