#!/bin/bash

VERSION=1.0.6

git clone https://github.com/GoogleCloudPlatform/kubernetes
pushd kubernetes
git checkout -b v$VERSION tags/v$VERSION

/opt/bin/kubectl create -f examples/guestbook/redis-master-controller.yaml
/opt/bin/kubectl create -f examples/guestbook/redis-master-service.yaml
/opt/bin/kubectl create -f examples/guestbook/redis-slave-controller.yaml
/opt/bin/kubectl create -f examples/guestbook/redis-slave-service.yaml
/opt/bin/kubectl create -f examples/guestbook/frontend-controller.yaml
/opt/bin/kubectl create -f examples/guestbook/frontend-service.yaml
/opt/bin/kubectl get pods
