# Zimbra FOSS -- Add a New Platform

## Overview

This document describes the process required to add support for a new
platform (distribution/version) to the Zimbra FOSS build ecosystem.

Although examples may reference a specific distribution, the procedure
is intentionally generic and can be reused for any future platform.

------------------------------------------------------------------------

## 1. Update zimbra-foss-builder

The `zimbra-foss-builder` project must first be updated to support the
new platform.

### 1.1 Review existing definitions

Compare:

-   The previous platform Dockerfile in
    https://github.com/Zimbra/zm-base-os\
    (e.g. `Dockerfile-devcore-<previous-platform>`)
-   The new platform Dockerfile in https://github.com/Zimbra/zm-base-os\
    (e.g. `Dockerfile-devcore-<new-platform>`)

Also review the corresponding Dockerfiles already present in
`zimbra-foss-builder`, for example:

-   `Dockerfiles/manual/<previous-platform>/Dockerfile`
-   `Dockerfiles/semiauto/<previous-platform>/Dockerfile`
-   `Dockerfiles/smart/<previous-platform>/Dockerfile`

### 1.2 Create new Dockerfiles

Based on the previous platform structure, create equivalent files for
the new platform:

-   `Dockerfiles/manual/<new-platform>/Dockerfile`
-   `Dockerfiles/semiauto/<new-platform>/Dockerfile`
-   `Dockerfiles/smart/<new-platform>/Dockerfile`

Keep changes minimal and aligned with the new base OS definition.

Commit:
```
Added <new-platform> support
```

### 1.3 Tag a new zimbra-foss-builder release

After validation, create and push a new version tag (example):

    vX.Y.Z

Document the exact version that introduces support for the new platform.

------------------------------------------------------------------------

## 2. Base Docker (zimbra-foss)

Before building any images for the new platform, a corresponding base
Docker image must be created in the `zimbra-foss` project.

### 2.1 Create base Docker definition

Review:

-   The new platform Dockerfile in https://github.com/Zimbra/zm-base-os
-   The previous platform base Dockerfile in:
    `Dockerfiles/github/<previous-platform>/Dockerfile`

Create:

-   `Dockerfiles/github/<new-platform>/Dockerfile`

Commit:
```
Added base Docker for <new-platform>
```

------------------------------------------------------------------------

## 3. Enable the Platform in CI Configuration

### 3.1 Update workflow templates

Edit:

    distros.json

Duplicate the previous platform entry and adjust values for the new
platform.

Commit:

``` bash
git add .github/workflow-templates/
git commit -m 'Added <new-platform> support (workflow-templates)'
```

### 3.2 Generate workflows

Run:

``` bash
cd .github/workflow-templates
./generate-build-workflows.py
cd ../..
```

Commit generated workflows:

``` bash
git add .github/workflows/
git commit -m 'Added <new-platform> support (workflows)'
```

------------------------------------------------------------------------

## 4. Build the Base Docker Image

1.  Push your working branch to ensure workflows trigger correctly:

``` bash
git push origin <feature-branch>
```

2.  Create and push a tag that triggers the base Docker build:

``` bash
git tag -a 'docker-builds-<new-platform>/v0.0.1' -m 'docker-builds-<new-platform>/v0.0.1'
git push origin 'docker-builds-<new-platform>/v0.0.1'
```

3.  Verify the workflow execution in the **Actions** tab.

------------------------------------------------------------------------

## 5. First Platform Build

Once the base Docker image is available and stable, proceed with
building the desired Zimbra release tag (e.g. `X.Y.Z`).

Ensure the build completes successfully before merging changes.

------------------------------------------------------------------------

## 6. Final Release

If everything is validated:

1.  Merge the feature branch into `main`.
2.  Push changes to origin.
3.  Publish a new project release tag.

Adding a new platform is a significant milestone.\
Tag appropriately and publish release notes describing the addition.

------------------------------------------------------------------------

# 7. Appendix -- Full Command Reference (Ubuntu 24.04)

This appendix consolidates all commands in execution order, grouped by
repository.

------------------------------------------------------------------------

## 7.1 In zimbra-foss-builder

``` bash
cd zimbra-foss-builder

mkdir -p Dockerfiles/manual/ubuntu-24.04
mkdir -p Dockerfiles/semiauto/ubuntu-24.04
mkdir -p Dockerfiles/smart/ubuntu-24.04

cp Dockerfiles/manual/ubuntu-22.04/Dockerfile Dockerfiles/manual/ubuntu-24.04/Dockerfile
cp Dockerfiles/semiauto/ubuntu-22.04/Dockerfile Dockerfiles/semiauto/ubuntu-24.04/Dockerfile
cp Dockerfiles/smart/ubuntu-22.04/Dockerfile Dockerfiles/smart/ubuntu-24.04/Dockerfile

git add Dockerfiles/
git commit -m "Added Ubuntu 24.04 support"

git tag -a v0.0.8 -m "Added Ubuntu 24.04 support"
git push origin v0.0.8
```

------------------------------------------------------------------------

## 7.2 In zimbra-foss

``` bash
cd zimbra-foss

mkdir -p Dockerfiles/github/ubuntu-24.04
cp Dockerfiles/github/ubuntu-22.04/Dockerfile Dockerfiles/github/ubuntu-24.04/Dockerfile

git add Dockerfiles/github/ubuntu-24.04/Dockerfile
git commit -m "Added base Docker for Ubuntu 24.04"

vim .github/workflow-templates/distros.json

git add .github/workflow-templates/
git commit -m "Added Ubuntu 24.04 support (workflow-templates)"

cd .github/workflow-templates
./generate-build-workflows.py
cd ../..

git add .github/workflows/
git commit -m "Added Ubuntu 24.04 support (workflows)"

git checkout -b ubuntu24-support-v1
git push origin ubuntu24-support-v1

git tag -a "docker-builds-ubuntu-24.04/v0.0.1" -m "docker-builds-ubuntu-24.04/v0.0.1"
git push origin "docker-builds-ubuntu-24.04/v0.0.1"

git checkout main
git merge ubuntu24-support-v1
git push origin main

git tag -a vX.Y.Z -m "Added Ubuntu 24.04 platform support"
git push origin vX.Y.Z
```
