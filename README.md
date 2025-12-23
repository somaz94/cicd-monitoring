# cicd-monitoring

A comprehensive collection of CI/CD pipelines and monitoring tools configurations for various cloud platforms and on-premise environments.

<br/>

## Directory Structure

<br/>

### AWS 

AWS-specific configurations and deployments for monitoring and CI/CD tools.

`aws`
- `argocd` - ArgoCD configurations for AWS
- `grafana` - Grafana dashboards and configurations
- `loki` - Loki logging stack setup
- `prometheus` - Prometheus monitoring configurations

<br/>

### GCP

Google Cloud Platform specific configurations and deployments.

`gcp`
- `argocd` - ArgoCD configurations for GCP
- `grafana` - Grafana dashboards and configurations
- `loki` - Loki logging stack setup
- `prometheus` - Prometheus monitoring configurations

<br/>

### On-Premise

Comprehensive on-premises configurations for various monitoring and CI/CD tools.

📁 `onpremise`
- `argocd` - Complete ArgoCD setup with Helm charts
  - `helm/charts` - Helm chart definitions
  - `helm/templates` - Kubernetes templates for various components
  - `helm/values` - Configuration values
- `elk-stack` - Elastic Stack components
  - `apm-server` - Application Performance Monitoring
  - `elasticsearch` - Search and analytics engine
  - `filebeat` - Log shipper
  - `kibana` - Data visualization
  - `logstash` - Log processing
  - `metricbeat` - Metrics collection
- `grafana` - Monitoring and visualization
  - `dashboards` - Pre-configured dashboards
  - `templates` - Kubernetes templates
- `ingress-nginx-sidecar-fluentbit` - Logging and ingress configuration
- `jenkins` - CI/CD server configurations
- `kube-prometheus-stack` - Kubernetes monitoring stack
  - `charts` - Helm charts
  - `templates` - Kubernetes templates for various exporters
- `loki` - Log aggregation system
  - `templates` - Component configurations
  - `values` - Deployment values
- `promtail` - Log collector
- `thanos` - Long-term metrics storage

<br/>

### GitLab CI/CD

GitLab CI/CD pipeline configurations and scripts.

📁 `gitlab-cicd`
- `script` - Pipeline scripts and utilities

<br/>

### GitLab Runner

GitLab Runner configurations and templates.

📁 `gitlab-runner`
- `templates` - Runner configuration templates

<br/>

### GitHub CI/CD

GitHub Actions workflows and configurations for different cloud platforms.

📁 `github-cicd`
- `aws`
  - `build-deploy-repo` - Build and deployment workflows
  - `data-repo` - Data management workflows
- `gcp`
  - `build-deploy-repo` - Build and deployment workflows
  - `data-build-deploy-repo` - Combined data and deployment workflows
  - `data-repo` - Data management workflows
  - `matrix-strategy` - Matrix build configurations
  - `upgrade-data-build-deploy-repo` - Upgrade workflows
- `aws-gcp` - Cross-cloud configurations

<br/>

### GitHub Runner

GitHub Actions runner configurations and controller setup.

📁 `github-runner`
- `actions-runner-controller`
  - `cr` - Custom Resources
  - `crds` - Custom Resource Definitions
  - `templates` - Runner templates

<br/>

## Getting Started

1. Choose your target platform (AWS, GCP, or On-Premise)
2. Navigate to the specific tool directory
3. Follow the README instructions in each directory for detailed setup steps
4. Configure the tools according to your environment needs

<br/>

## Notes

- Each directory contains its own README with specific instructions
- Configuration files are organized by platform and tool
- Templates and values are provided for easy customization
- Some components may require additional setup or dependencies

<br/>

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.
