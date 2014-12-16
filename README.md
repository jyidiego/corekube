## Corekube
Last Update: 12/11/2014

## TL;DR

#### Versions
CoreOS version used: [v509.1.0 - Alpha](https://coreos.com/releases/#509.1.0)

Kubernetes version used: [v0.6.2](https://github.com/GoogleCloudPlatform/kubernetes/releases/tag/v0.6.2)

#### Contributing
Please create all pull requests against the 'dev' branch. The
'master' branch is reserved for working releases, complete with updated
docs, etc.

See [HACKING](https://github.com/metral/corekube/blob/master/HACKING.md) for
more information.

#### Blog Post

[Full Blog Post on Rackspace Developer Blog](https://developer.rackspace.com/blog/running-coreos-and-kubernetes/)

#### Corekube Deployment

```
heat stack-create corekube --template-file corekube-heat.yaml -P key-name=<RAX_SSH_KEYNAME>
```

#### Using Kubernetes on the Corekube Deployment
[How to run examples on Kubernetes](#kubernetes-usage)

------------------

## Introduction
Corekube is an adapation of CoreOS's [Running Kubernetes Example on CoreOS](https://coreos.com/blog/running-kubernetes-example-on-CoreOS-part-2/) blog post.

"Running Kubernetes Example on CoreOS" describes the installation of Kubernetes with VMWare, some manual network configuration & the deployment of the Kubernetes master & minion stacks via cloud-config.

Corekube has a heavy foundation on the CoreOS post, but with a couple of modifications:

* It uses Openstack (Rackspace Orchestration/Heat, Cloud Networks and Cloud Servers) & CoreOS's cloud-config to allow for:
    * Deployment of virtual resources required by both CoreOS and Kubernetes via OpenStack on the Rackspace Public Cloud
    * Creation of a repeatable template to instantiate, setup & bootstrap a proof-of-concept of a Kubernetes cluster running atop of CoreOS
* It also uses etcd & fleet API's to instantiate a Kubernetes role on a CoreOS machine
    * Utilizing the API's not only allows for the dynamic bootstrapping of CoreOS machines to assume a Kubernetes role, but creates the opportunity for expansion of the cluster in the future - abilities that are out of the scope of an all cloud-config based setup such as the one demonstrated in the CoreOS post
        * This would only require to point new machines to the etcd discovery node and then use our same mechanisms to provision it - more on this below

## Setup & Installation

**Heat Template**

At the helm of CoreKube is an OpenStack Heat template that lays down the
following infastructure in an ordered fashion, with discovery & priv_network
being built first, and then kubernetes-master-x, kubernetnes-minion-y and overlord
afterwords.

* "discovery" - CoreOS Cloud Server - Private etcd used for cluster discovery
* "priv_network" - Cloud Network - Isolated layer 2 network used in an overlay
  network to supply Kubernetes with its own subnet
* "kubernetes-master-x" - CoreOS Cloud Server - Assumes the Kubernetes Master role
* "kubernetes-minion-y" - CoreOS Cloud Server - Assumes the Kubernetes Minion role
* "overlord" - CoreOS Cloud Server - Gathers cluster information & provisions Kubernetes roles onto the Kuberenetes-\* host machines

**Discovery**

The first step in Corekube's process, after server creation, is to instantiate a private discovery node using etcd, which is required for
the cluster of overlord, kubernetes-master-x, and kubernetes-minion-y nodes.

The discovery service is provided by the [coreos/etcd](https://registry.hub.docker.com/u/coreos/etcd/)
Docker repo with a unique cluster UUID generated at creation via Heat.

This discovery node's IP, combined with the cluster UUID, are used to assemble the complete discovery path needed by the etcd services (as well as the fleet service since it depends on etcd) for
the rest of the infrastructure.

Therefore, by the cluster nodes directly connecting to the discovery node, they have the information necessary to communicate with each other via fleetctl - the mechanism with which we deploy the Kubernetes role onto the designated machine.

<p align="center"><img src="images/discovery.png"></p>

**Networking**

Once each machine has booted & connected their etcd service to the private discovery node (and fleet/fleetctl is ready to make use of this connection), a network architecture must be established to allow the containers that the Kuberentes nodes operate to communicate with one-another on their own subnet.

In order to understand the proposed networking architecture described below, we must first understand at a high-level how networking works with regards to Docker:

* By default, Docker creates a virtual interface, specically a virtual Ethernet bridge (aka a linux bridge), named docker0 on the host machine
* If docker0 does not have an address and subnet, which by default it does not, Docker randomly chooses an address and subnet from the private range defined by RFC 1918 that are not in use on the host machine, and assigns it to docker0.
* Because docker0 is a linux bridge, it automatically forwards packets between any other network interfaces that are attached to it
* So, every time Docker creates a container, it creates a pair of “peer” interfaces, specifically a virtual ethernet device (aka an veth device), that are like opposite ends of a pipe - this lets containers communicate both with the host machine and with each other

Now that we know how containers on Docker talk to other containers on the same host, we need to figure out how to allow containers on *different* hosts to have the same capability; specifically, when using a Rackspace Cloud Network, as it provides the servers an additional & isolated Layer 2 network.

To allow the containers to communicate with each other via its Kubernetes host machine (which has an interface on the isolated layer 2 network), their must be some sort of networking mechanism to allow for it.

However, its worth noting that on a Rackspace Cloud Network, MAC filtering is performed; therefore, any traffic that originates on the docker0 linux bridge by the container will *not* be able to inherently communicate with the rest of the docker0 linux bridges in the rest of the cluster.

Fortunately, there is a solution that helps us in various ways: establish a multicast [vxlan overlay](http://en.wikipedia.org/wiki/Virtual_Extensible_LAN) on top of the Cloud Network.

Since vxlan's function by encapsulating the MAC-based layer 2 ethernet frames within layer 4 UDP packets, and because we can create one to operate on multicast mode, we can accomplish a couple of goals:

* We get around the MAC filtering that the Cloud Network imposes, as vxlan traffic will still originate from the Cloud Network MAC address, and not the linux bridge used by Docker when a container creates the traffic
* Communication paths for the entire group of all Kubernetes host machines & containers becomes automatically established because multicast allows all machines (hosts & containers) to not only send packets, but also, receive all packets sent on the overlay network; therefore, both Kubernetes host machines and containers can communicate with one another on their own subnet.

Below is the proposed network architecture that is configured on the Kubernetes machines using [CoreOS' Flannel](https://github.com/coreos/flannel) via cloud-config & systemd units:

* Each Kubernetes machine will have an interface, named "eth2", on the isolated L2 192.168.3.0/24 Cloud Network
* Flannel then creates a TUN/TAP device named "flannel.1" that overlays onto the eth2 device
* Flannel also chooses a random subnet ID from the CIDR 10.244.0.0/15 that we've designated for the Flannel configuration and an MTU and assigns it to flannel.1
    * i.e 10.244.94.0/15
* Flannel then requests a subnet lease on 10.244.0.0/15 for the Docker bridge
* We then update the Docker bridge interface's host CIDR by assigning it the new subnet chosen by Flannel (relevant to the overlay CIDR), and drop both the Docker bridge CIDR and flannel.1's MTU into /run/flannel/subnet.env so that we can make the Docker daemon aware of the new configuration
    * i.e. $ cat /run/flannel/subnet.env
        * FLANNEL_SUBNET=10.244.94.1/24
        * FLANNEL_MTU=1450
* Docker is then restarted to take into account the new Docker bridge host CIDR & the flannel.1 MTU
* The Docker bridge is now set to instantiate containers on the new CIDR and depends on the host routing table to route all overlay traffic on the 10.244.0.0/15 CIDR via flannel.1

<p align="center"><img src="images/networking.png"></p>

**Note**: If you have RackConnect v2 enabled you will require rules like the ones
below.  If you don't know what RackConnect is, you may safely ignore this.

* Dedicated -> Cloud Source=Network [192.168.3.0/24] Destination Type [All] Protocol [All]
* Dedicated -> Cloud Source=Network [10.244.0.0/15] Destination Type [All] Protocol [All]

**Note**: If you have RackConnect v3 enabled you must use the corekube-heat-rackconnectv3.yaml file and specify you RackConnect network id by setting the parameter rackconnect-network

**Overlord**

As you may have noticed in the "Cluster Discovery" figure above, there is an additional CoreOS server in addendum to the Kubernetes machines: the Overlord.

The Overlord is a custom [Go](http://golang.org/) package that operates in a Docker container.
After it's etcd service discovers the rest of the cluster via the private discovery service, it is tasked with the following responsibilities:

* Using the local etcd API, wait for all expected machines in the cluster to show up in etcd & collect their relevant data
* Using the local etcd API, wait for all expected machines in the cluster to have their fleet metadata be available & collect it
* Create systemd unit files for the Kubernetes master & minion machines from pre-existing templates
    * These templates are populated with relevant information collected locally, such as the dependent machines & criteria a Kubernetes node needs to operate
* Using the local fleet API, start the batch of templates that deal with downloading the Kubernetes master & minion binaries to the respective CoreOS host
* Using the local fleet API, start the batch of templates that deal with instantiating & running the Kubernetes master & minion binaries on the respective CoreOS host

The Overlord's tasks are best described in the following figure:

<p align="center"><img src="images/flow.png"></p>

<a name="overlord-tasks"></a>
To view the Overlord's progress and status, log into the the "overlord" server and examine the Docker container, it operates: "setup\_kubernetes"

```
$ ssh root@<overlord_ip>
```

**Note**: Building the setup\_kubernetes container and running it can take
several minutes, so refresh the following commands below until its output
resembles yours.

Review the Docker image pulled:

```
$ docker images

REPOSITORY          TAG                 IMAGE ID            CREATED             VIRTUAL SIZE
overlord            master              a3a95c2e3b1c        6 hours ago         604.9 MB
google/golang       stable              e0d9d5bb3d3d        5 days ago          559.6 MB
```

Review all Docker processes:

```
$ docker ps -a

CONTAINER ID        IMAGE                     COMMAND                CREATED
14678dc12d55        overlord:master           /gopath/bin/overlord   6 hours ago
```

Review the logs of the overlord's container:

```
$ docker logs 14678dc12d55

2014/09/09 03:36:45
Fleet Machine:
-- ID: ca2ebc1eec234e6da36a2cb059517e89
-- PublicIP: 10.208.198.136
-- Metadata: (kubernetes_role => master)

2014/09/09 03:36:45
Fleet Machine:
-- ID: a2b84acbad074566ae21874d5e7fa58e
-- PublicIP: 10.208.200.28
-- Metadata: (kubernetes_role => minion)

2014/09/09 03:36:45
Fleet Machine:
-- ID: 78e09cc2d73549f982701658bacab491
-- PublicIP: 10.208.198.205
-- Metadata: (kubernetes_role => minion)

2014/09/09 03:36:45
Fleet Machine:
-- ID: 5cd010084c8b48158a4c579650080405
-- PublicIP: 10.208.199.254
-- Metadata: (kubernetes_role => minion)

2014/09/09 03:36:45 Created systemd unit files for kubernetes deployment
2014/09/09 03:36:45 Waiting for (4) services to be complete in fleet. Currently at: (0)
2014/09/09 03:36:48 Waiting for (4) services to be complete in fleet. Currently at: (0)
2014/09/09 03:36:49 Waiting for (4) services to be complete in fleet. Currently at: (2)
2014/09/09 03:36:50 Waiting for (4) services to be complete in fleet. Currently at: (3)
2014/09/09 03:36:57 Unit files in '/units/kubernetes_units/download' have completed
2014/09/09 03:36:59 Waiting for (8) services to be complete in fleet. Currently at: (0)
2014/09/09 03:37:02 Waiting for (8) services to be complete in fleet. Currently at: (4)
2014/09/09 03:37:03 Unit files in '/units/kubernetes_units/roles' have completed
```

## Kubernetes Usage

Once the Heat template finishes instantiating the Heat template, the resources are booted & initiated, and we've [verified that the Overlord's setup\_kubernetes container ran & exited successfully](#overlord-tasks), we can begin using the [examples](https://github.com/GoogleCloudPlatform/kubernetes#where-to-go-next) available that showcase Kubernetes capabilities.

Follow this set of steps to get you started:

* SSH into the Kubernetes Master node as the 'root' user using your RAX SSH keypair

    ```
    $ ssh root@<master_ip>
    ```

* Run the [Guestbook example](https://github.com/GoogleCloudPlatform/kubernetes/blob/master/examples/guestbook/README.md) offered by Kubernetes (of which has been compiled
  into a shell script):

    ```
    $ curl -sKS -L https://raw.githubusercontent.com/metral/corekube/master/guestbook-example.sh | bash
    ```

* Monitor the status of the guestbook deployment until all are in the "Running"
  state:

    ```
    $ /opt/bin/kubectl get pods
    ```

**Note:**

* You can assume that your Kubernetes cluster is operational if you've gotten
  to this point, so disregard the setup cluster instructions (Step 0) in the Kubernetes
  examples
* After you complete the deployment of the guestbook, it could take a couple of minutes before the frontend nodes are accessible, so be patient.
