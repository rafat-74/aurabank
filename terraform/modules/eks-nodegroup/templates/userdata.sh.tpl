#!/bin/bash
set -o xtrace

# Join this node to the EKS cluster
/etc/eks/bootstrap.sh '${cluster_name}' \
  --b64-cluster-ca '${cluster_ca}' \
  --apiserver-endpoint '${cluster_endpoint}' \
  ${bootstrap_extra_args} \
  --kubelet-extra-args '--node-labels=${join(",", [for k, v in node_labels : "${k}=${v}"])}':x
