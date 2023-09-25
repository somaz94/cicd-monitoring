# Jenkins Installation Guide on Kubernetes

<br/>

## Table of Contents
- [Create Jenkins Namespace](#create-jenkins-namespace)
- [Install certmanager and letsencrypt Setting](#install-certmanager-and-letsencrypt-setting)
- [Install nfs-provisioner](#install-nfs-provisioner)
- [Install Jenkins and Upgrade](#install-jenkins-and-upgrade)
- [ADD Ingress](#add-ingress)
- [Jenkins CLI](#jenkins-cli)
- [Additional Information](#additional-information)

<br/>

## Create Jenkins Namespace
```bash
kubectl create ns jenkins
```

<br/>

## Install certmanager and letsencrypt Setting
- [certmanager-letsencrypt](https://github.com/somaz94/certmanager-letsencrypt)

<br/>

## Install nfs-provisioner
- [nfs-subdir-external-provisioner](https://kubernetes-sigs.github.io/nfs-subdir-external-provisioner)

<br/>

## Install Jenkins and Upgrade
```bash
helm install jenkins -f jenkins-values.yaml -n jenkins jenkins/jenkins
helm upgrade jenkins -f jenkins-values.yaml -n jenkins jenkins/jenkins # Upgrade Method
```

<br/>

## ADD Ingress
```bash
kubectl apply -f jenkins-ingress.yaml -n jenkins
```

<br/>

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

<br/>

#### Additional Information
Modify the Domain, host, part in all yaml files.
