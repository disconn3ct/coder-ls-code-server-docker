---
name: Use Code Server to Develop with Docker
description: A workspace environment with Code Server and Docker.
tags:
  [
    cloud,
    kubernetes,
    linuxserver,
    code-server,
    vscode,
    webide,
    docker,
    dind,
    k8s-dind,
    dind-rootless,
  ]
---

# Getting started

This template creates a pod running the [Code-Server](https://github.com/linuxserver/docker-code-server) image from LinuxServer, with Docker support, custom added packages and a [Coder](https://github.com/coder/coder) agent.

## Docker

The workspace can optionally include the DIND docker-mod from https://github.com/linuxserver/docker-mods/tree/universal-docker-in-docker

## RBAC

The Coder provisioner requires permission to administer pods and configmaps to use this template. The template
creates workspaces in a single Kubernetes namespace, using the `workspaces_namespace` parameter set while creating the template.

Create a role as follows and bind it to the user or service account that runs the coder host. If you are using separate namespaces for coder and workspaces, this should be a ClusterRole.

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: coder
rules:
  - apiGroups: [""]
    resources: ["pods"]
    verbs: ["*"]
  - apiGroups: [""]
    resources: ["configmaps"]
    verbs: ["*"]
```

## Authentication

This template can authenticate using in-cluster authentication, or using a kubeconfig local to the
Coder host. For additional authentication options, consult the [Kubernetes provider
documentation](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs).

### kubeconfig on Coder host

If the Coder host has a local `~/.kube/config`, you can use this to authenticate
with Coder. Make sure this is done with same user that's running the `coder` service.

To use this authentication, set the parameter `use_kubeconfig` to true.

### In-cluster authentication

If the Coder host runs in a Pod on the same Kubernetes cluster as you are creating workspaces in,
you can use in-cluster authentication.

To use this authentication, set the parameter `use_kubeconfig` to false.

The Terraform provisioner will automatically use the service account associated with the pod to
authenticate to Kubernetes. Be sure to bind a [role with appropriate permission](#rbac) to the
service account. For example, assuming the Coder host runs in the same namespace as you intend
to create workspaces:

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: coder

---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: coder
subjects:
  - kind: ServiceAccount
    name: coder
roleRef:
  kind: Role
  name: coder
  apiGroup: rbac.authorization.k8s.io
```

Then start the Coder host with `serviceAccountName: coder` in the pod spec.

## Namespace

The target namespace in which the pod will be deployed is defined via the `coder_workspace`
variable. The namespace must exist prior to creating workspaces.

## Persistence

The `/config` directory in this workspace is persisted via the attached PersistentVolumeClaim.
Any data saved outside of this directory will be lost when the workspace stops. This includes `/usr/local` and any extra system packages installed.

### Persist Docker

If `enable_docker` and `persist_docker` are both true, the `docker` sidecar will use `/config/workspace/.docker-data` to store data such as images, layers and caches. If this is false, Docker data will be lost each time the workspace stops.

If `persist_docker` is `true`, Docker data should be managed only by the Docker CLI (for example,
`docker system prune -a`). To remove all Docker data, set `persist_docker` to `false` when starting the workspace, then use the terminal to remove `/config/workspace/.docker-data`.
