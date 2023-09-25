# GitHub CI/CD Configuration Guide

This guide provides an overview of how to correctly set up and configure your GitHub Actions CI/CD.

<br/>

## Variables Configuration

- **Storage**: GitHub Action variables should be stored under `Settings` > `Secrets and Variables` > `Actions`.
- **Scope**: Variables can either be saved per repository or at the organization level, making them accessible across all repositories.
- **Example Pipelines**: All provided pipelines in this directory are GitHub Action examples.

<br/>

## Action Modules

Here's a collection of some commonly used GitHub Action modules:

<br/>

#### General Utilities:
- [changed-files (by tj-actions)](https://github.com/tj-actions/changed-files)
- [checkout (by actions)](https://github.com/actions/checkout)

<br/>

#### Secrets and SSH:
- [branch-based-secrets (by noliran)](https://github.com/noliran/branch-based-secrets)
- [ssh-deploy (by easingthemes)](https://github.com/easingthemes/ssh-deploy)
- [ssh-action (by appleboy)](https://github.com/appleboy/ssh-action)

<br/>

#### Repository and Docker:
- [repository-dispatch (by peter-evans)](https://github.com/peter-evans/repository-dispatch)
- [login-action (by docker)](https://github.com/docker/login-action)
- [setup-buildx-action (by docker)](https://github.com/docker/setup-buildx-action)
- [build-push-action (by docker)](https://github.com/docker/build-push-action)

<br/>

#### Messaging and Setup:
- [slack-github-action (by slackapi)](https://github.com/slackapi/slack-github-action)
- [setup-python (by actions)](https://github.com/actions/setup-python)
- [github-script (by actions)](https://github.com/actions/github-script)

<br/>

#### Cloud Platforms:
- [auth (by google-github-actions)](https://github.com/google-github-actions/auth)
- [setup-gcloud (by google-github-actions)](https://github.com/google-github-actions/setup-gcloud)
- [configure-aws-credentials (by aws-actions)](https://github.com/aws-actions/configure-aws-credentials)
- [amazon-ecr-login (by aws-actions)](https://github.com/aws-actions/amazon-ecr-login)
