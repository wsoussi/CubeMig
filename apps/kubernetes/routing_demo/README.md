## routing_demo

`routing_demo` is a minimal Kubernetes application designed to demonstrate **Istio based traffic routing and migration across clusters**.

The application is intentionally simple. Its purpose is not business logic, but observability. It makes routing behavior visible and easy to reason about.

## Purpose

This application exists to demonstrate:

• how traffic can be redirected without changing clients  
• how a workload can move between clusters transparently  
• how Istio routing rules affect live traffic  
• how migrations can be verified visually and functionally  

It is especially useful in multi cluster Istio setups, including primary remote topologies.

## Application behavior

The application exposes a single HTTP endpoint.

### Endpoint

`GET /whoami`

Each request returns a JSON response containing:

• `cluster`  
the name of the Kubernetes cluster where the pod is running  

• `version`  
the application version, injected from the pod label `version`  

• `counter`  
a per pod in memory counter  
starts at 1  
increments on every request  

The counter resets when traffic moves to a new pod, making migrations immediately visible.

## Why this design works for routing demos

• the response clearly shows where the request was served  
• version changes are visible without inspecting Kubernetes  
• counter resets prove traffic redirection, not retries  
• no IP addresses are required, avoiding misleading signals  
• works cleanly with Istio, Kiali, and Prometheus  

When traffic is shifted using an Istio `VirtualService`, responses flip from one cluster and version to another without restarting clients or changing URLs.

## Configuration model

The application receives all runtime context from Kubernetes.

Injected at deployment time:

• `CLUSTER_NAME`  
static environment variable  
different per cluster  

• `APP_VERSION`  
injected from `metadata.labels['version']` using the Downward API  

No configuration is baked into the container image.

The same image can be deployed unchanged to multiple clusters.

## Kubernetes and Istio integration

• runs as a standard Deployment  
• exposed via a Kubernetes Service  
• Istio sidecar enabled  
• traffic controlled exclusively via Istio routing rules  

The Service name is the stable identity.  
Pods and clusters are interchangeable backends.

## Intended usage

This app is intended for:

• demonstrating blue green and cutover routing  
• validating multi cluster service discovery  
• showing Istio behavior in Kiali graphs  
• teaching traffic management concepts  
• migration scripts and automated demos  

It is not intended for production workloads.

## Summary

`routing_demo` is a deliberately boring application that makes complex routing behavior obvious.  
If traffic moves, the response tells you immediately where it went and why.
