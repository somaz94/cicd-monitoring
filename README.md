# cicd-monitoring
Collection of cicd pipelines.
How to install the monitoring tool.

## AWS
```bash
└── aws
    ├── argocd
    │   ├── README.md
    │   ├── argocd-ingress.yaml
    │   └── repo-secret.yaml
    ├── grafana
    │   ├── README.md
    │   ├── ebs-csi-pv.yaml
    │   ├── ebs-csi-sc.yaml
    │   ├── efs-csi-pv.yaml
    │   ├── efs-csi-sc.yaml
    │   └── values.yaml
    ├── loki
    │   ├── README.md
    │   ├── ebs-csi-pv.yaml
    │   ├── ebs-csi-sc.yaml
    │   ├── efs-csi-pv.yaml
    │   ├── efs-csi-sc.yaml
    │   └── values.yaml
    └── prometheus
        ├── README.md
        ├── ebs-csi-pv-prometheus-alertmanager.yaml
        ├── ebs-csi-pv-prometheus-server.yaml
        ├── ebs-csi-sc.yaml
        ├── efs-csi-pv-prometheus-alertmanager.yaml
        ├── efs-csi-pv-prometheus-server.yaml
        ├── efs-csi-sc.yaml
        ├── extra-scrape-configs-values.yaml
        └── values.yaml
```

## GCP
```bash
└── gcp
    ├── argocd
    │   ├── README.md
    │   ├── argocd-certificate.yaml
    │   ├── argocd-ingress.yaml
    │   └── repo-secret.yaml
    ├── grafana
    │   ├── README.md
    │   ├── fs-csi-pv.yaml
    │   ├── fs-csi-sc-shared-vpc.yaml
    │   ├── fs-csi-sc.yaml
    │   ├── grafana-certificate.yaml
    │   ├── grafana-ingress.yaml
    │   ├── nfs-pv.yaml
    │   ├── nfs-sc-README.md
    │   ├── pd-csi-pv.yaml
    │   ├── pd-csi-sc.yaml
    │   └── values.yaml
    ├── loki
    │   ├── README.md
    │   ├── fs-csi-pv.yaml
    │   ├── fs-csi-sc-shared-vpc.yaml
    │   ├── fs-csi-sc.yaml
    │   ├── loki-certificate.yaml
    │   ├── loki-ingress.yaml
    │   ├── nfs-pv.yaml
    │   ├── nfs-sc-README.md
    │   ├── pd-csi-pv.yaml
    │   ├── pd-csi-sc.yaml
    │   └── values.yaml
    └── prometheus
        ├── README.md
        ├── extra-scrape-configs-values.yaml
        ├── fs-csi-pv-prometheus-alertmanager.yaml
        ├── fs-csi-pv-prometheus-server.yaml
        ├── fs-csi-sc-shared-vpc.yaml
        ├── fs-csi-sc.yaml
        ├── nfs-pv-prometheus-alertmanager.yaml
        ├── nfs-pv-prometheus-server.yaml
        ├── nfs-sc-README.md
        ├── pd-csi-pv-prometheus-alertmanager.yaml
        ├── pd-csi-pv-prometheus-server.yaml
        ├── pd-csi-sc.yaml
        ├── prometheus-certificate.yaml
        ├── prometheus-ingress.yaml
        └── values.yaml
```


