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

data "coder_parameter" "persist_docker" {
  type        = "bool"
  name        = "Persist Docker"
  mutable     = true
  default     = false
  description = <<-EOF
  Preserve Docker data across restarts? (true/false)

  This has no effect if 'enable_docker' is false.

  Set this to false (default) if the Docker data should be ephemeral.
  All Docker data (images, build cache, containers, networks, etc) will be
  lost every time the workspace is stopped. Docker will have access to about
  16Gi of storage.

  Set this to true to persist Docker data under `$HOME`, using the workspace
  quota. This can consume large amounts of storage, and needs to be
  maintained inside the workspace using the appropriate `docker` commands.

  Some user configuration is normally stored under `$HOME`, and those files
  are not affected by this setting and may not be preserved across restarts.
  EOF
}

data "coder_parameter" "docker_version" {
  name        = "Docker version"
  type        = "string"
  mutable     = true
  description = <<-EOF
    Docker package version to install from https://download.docker.com/linux/ubuntu/dists/jammy/pool/stable/amd64
    (More information: https://docs.docker.com/engine/install/ubuntu/#install-from-a-package)
    EOF
  default     = "24.0.5-1"
}

data "coder_parameter" "docker_compose_version" {
  name        = "Docker Compose version"
  type        = "string"
  mutable     = true
  description = <<-EOF
    Docker Compose package version to install from https://download.docker.com/linux/ubuntu/dists/jammy/pool/stable/amd64
    (More information: https://docs.docker.com/engine/install/ubuntu/#install-from-a-package)
    EOF
  default     = "2.20.2-1"
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
  `/tmp/coder.??????/coder dotfiles URL` inside the workspace terminal instead.
  EOF
  default     = ""
}

data "coder_parameter" "extra_package_list" {
  type        = "list(string)"
  mutable     = true
  name        = "Extra Packages"
  description = <<-EOF
  A list of Ubuntu packages to install.

  Docker and docker-compose packages will be removed and replaced with upstream
  packages.

  These packages are installed during every workspace startup and may cause delays
  before the workspace is available.

  The default includes some basic command-line tools for networking, file viewing and
  editing, plus the fish shell and Python 3. This takes approximately 2 minutes to install.
  EOF
  default = jsonencode([
    "python-is-python3",
    "python3-minimal",
    "python3-pip",
    "dnsutils",
    "diffstat",
    "most",
    "curl",
    "wget",
    "psmisc",
    "vim-nox",
    "clang-format",
    "grc",
    "fzy",
    "netcat",
    "fish",
  ])
}

data "coder_parameter" "image_version" {
  type        = "string"
  name        = "Linuxserver/Code-Server Docker Tag"
  description = "Docker tag for LinuxServer/Code-Server"
  mutable     = true
  default     = "latest"
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
  startup_script = data.coder_parameter.dotfiles_uri.value != "" ? "/tmp/coder.??????/coder dotfiles -y ${data.coder_parameter.dotfiles_uri.value}" : null

  env = {
    "CODER_TELEMETRY" = "false"
    # So Terminal and SSH can use docker:
    "DOCKER_TLS_CERTDIR" = tobool(data.coder_parameter.enable_docker.value) ? "/shared" : null
    "DOCKER_CONFIG"      = tobool(data.coder_parameter.enable_docker.value) ? "/shared/client/" : null
    "DOCKER_HOST"        = tobool(data.coder_parameter.enable_docker.value) ? "localhost:2376" : null
    "DOCKER_TLS"         = tobool(data.coder_parameter.enable_docker.value) ? "true" : null
    # And to align with the IDE:
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
    script       = "/tmp/coder.??????/coder stat cpu"
    interval     = 10
    timeout      = 1
  }

  metadata {
    display_name = "RAM Usage"
    key          = "1_ram_usage"
    script       = "/tmp/coder.??????/coder stat mem"
    interval     = 10
    timeout      = 1
  }

  metadata {
    display_name = "Home Disk"
    key          = "3_home_disk"
    script       = "/tmp/coder.??????/coder stat disk --path $HOME"
    interval     = 60
    timeout      = 1
  }

  metadata {
    display_name = "CPU Usage (Host)"
    key          = "4_cpu_usage_host"
    script       = "/tmp/coder.??????/coder stat cpu --host"
    interval     = 10
    timeout      = 1
  }

  metadata {
    display_name = "Memory Usage (Host)"
    key          = "5_mem_usage_host"
    script       = "/tmp/coder.??????/coder stat mem --host"
    interval     = 10
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

    "docker-install.sh" = <<-EOINIT
      #!/bin/bash
      set -euo pipefail
      ${tobool(data.coder_parameter.enable_docker.value) ? "" : "# Docker disabled\nexit 0"}

      # Docker container will fail on first startup until the directory is created
      # This also force-creates a .dockerignore to prevent Docker uploading itself to itself
      ${tobool(data.coder_parameter.persist_docker.value) ? "mkdir -p $HOME/workspace/.docker-data || true; chown 1000:1000 $HOME/workspace/.docker-data; echo .docker-data > $HOME/workspace/.dockerignore" : "# empty"}

      # install docker client
      . /etc/os-release
      UBUNTU_ARCH="$(dpkg --print-architecture)"
      apt remove -y docker docker-engine docker.io containerd runc || true
      curl -fsSLo /tmp/docker-ce-cli.deb https://download.docker.com/linux/ubuntu/dists/$${UBUNTU_CODENAME}/pool/stable/$${UBUNTU_ARCH}/docker-ce-cli_${data.coder_parameter.docker_version.value}~ubuntu.$${VERSION_ID}~$${UBUNTU_CODENAME}_$${UBUNTU_ARCH}.deb
      curl -fsSLo /tmp/docker-compose-plugin.deb https://download.docker.com/linux/ubuntu/dists/$${UBUNTU_CODENAME}/pool/stable/$${UBUNTU_ARCH}/docker-compose-plugin_${data.coder_parameter.docker_compose_version.value}~ubuntu.$${VERSION_ID}~$${UBUNTU_CODENAME}_$${UBUNTU_ARCH}.deb
      dpkg -i /tmp/docker-ce-cli.deb /tmp/docker-compose-plugin.deb
      rm   -f /tmp/docker-ce-cli.deb /tmp/docker-compose-plugin.deb
    EOINIT
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
      image             = "ghcr.io/linuxserver/code-server:${data.coder_parameter.image_version.value}"
      image_pull_policy = "Always"
      port {
        name           = "http"
        container_port = 8443
      }
      # UID/GID must align with dind-rootless. Hardcoded: https://github.com/docker-library/docker/blob/c13cbee1cfd9d7582f7b2e9f958cf24e39b64715/20.10/dind-rootless/Dockerfile
      env {
        name  = "PUID"
        value = "1000"
      }
      env {
        name  = "PGID"
        value = "1000"
      }
      # These are LinuxServer addons, not related to enable-docker
      env {
        name  = "DOCKER_MODS"
        value = "linuxserver/mods:universal-package-install"
      }
      env {
        name  = "INSTALL_PACKAGES"
        value = join("|", jsondecode(data.coder_parameter.extra_package_list.value))
        # tostring(data.coder_parameter.extra_package_list.value)
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
      #  value = "/tmp/coder.??????/coder gitssh --"
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

      # To connect to dind:
      dynamic "env" {
        # If docker is enabled, add these envs:
        for_each = tobool(data.coder_parameter.enable_docker.value) ? [
          {
            name  = "DOCKER_TLS_CERTDIR"
            value = "/shared"
          },
          {
            name  = "DOCKER_CONFIG"
            value = "/shared/client/"
          },
          {
            name  = "DOCKER_HOST"
            value = "localhost:2376"
          },
          {
            name  = "DOCKER_TLS"
            value = "true"
          }
        ] : []
        content {
          name  = env.value["name"]
          value = env.value["value"]
        }
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
      dynamic "volume_mount" {
        for_each = tobool(data.coder_parameter.enable_docker.value) ? [1] : []
        content {
          mount_path = "/shared"
          name       = "docker-tls"
          read_only  = false
        }
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

    dynamic "container" {
      for_each = data.coder_parameter.enable_docker.value ? [1] : []

      content {
        name  = "docker"
        image = "docker:dind-rootless"
        env {
          name  = "DOCKER_TLS_CERTDIR"
          value = "/shared"
        }
        # TODO: Use sysbox or similar to run unprivileged
        security_context {
          privileged = true
        }

        resources {
          requests = {
            cpu    = "10m"
            memory = "100Mi"
          }
          limits = {
            cpu    = "1000m"
            memory = "1Gi"
          }
        }

        # Generated certificates
        volume_mount {
          mount_path = "/shared"
          name       = "docker-tls"
          read_only  = false
        }

        dynamic "volume_mount" {
          # This is odd but basically amounts to "if persist-docker, then insert the volume-mount"
          for_each = data.coder_parameter.persist_docker.value ? [1] : []
          content {
            mount_path = "/home/rootless/"
            name       = "home"
            sub_path   = "workspace/.docker-data"
            read_only  = false
          }
        }
      }
    }
    volume {
      name = "home"
      persistent_volume_claim {
        claim_name = kubernetes_persistent_volume_claim.home.metadata.0.name
        read_only  = false
      }
    }
    dynamic "volume" {
      for_each = data.coder_parameter.enable_docker.value ? [1] : []
      content {
        name = "docker-tls"
        empty_dir {
          medium     = "Memory"
          size_limit = "100M"
        }
      }
    }
    dynamic "volume" {
      # dind storage (image cache etc)
      # if enable-docker and NOT persist-docker, then insert the volume
      for_each = tobool(data.coder_parameter.enable_docker.value) ? (tobool(data.coder_parameter.persist_docker.value) ? [] : [1]) : []
      content {
        name = "docker"
        empty_dir {
          size_limit = "16Gi"
        }
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
