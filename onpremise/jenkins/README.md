## Create Jenkins Namespace

```bash
kubectl create ns jenkins

```

## Intsall certmanager and letsencrypt Setting
- [certmanager-letsencrypt](https://github.com/somaz94/certmanager-letsencrypt)

## Install nfs-provisioner
- [nfs-subdir-external-provisioner](https://kubernetes-sigs.github.io/nfs-subdir-external-provisioner)

## Install Jenkins and Upgrade

```bash

helm install jenkins -f jenkins-values.yaml -n jenkins jenkins/jenkins
helm upgrade jenkins -f jenkins-values.yaml -n jenkins jenkins/jenkins # Upgrdae Method
```

## ADD Ingress

```bash
kubectl apply -f jenkins-ingress.yaml -n jenkins
```

## Jenkins CLI

```bash
wget http://jenkins.somaz.link/jnlpJars/jenkins-cli.jar

# Check Version
java -jar jenkins-cli.jar -s http://jenkins.somaz.link/ -auth <user>:<api-token> -version
Version: 2.414.1

# Copy Job
java -jar jenkins-cli.jar -s http://jenkins.somaz.link/ -auth <user>:<api-token> copy-job <origin-job> <copy-job>

# Reload Configuration
java -jar jenkins-cli.jar -s http://jenkins.somaz.link/ -auth <user>:<api-token> reload-configuration
```

#### In addition
Modify the Domain, host, part in all yaml files.

