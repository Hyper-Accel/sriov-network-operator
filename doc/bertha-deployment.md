# Bertha Thor 2 deployment

This profile uses the existing operator chart. It creates **one VF per PF** on
two explicitly selected Broadcom BCM957608-P1400GDF00 PFs per enabled node.
The expected healthy capacity is `hyperaccel.ai/bertha_rnic: 2` per node, or
eight VFs across `bertha-xlarge-101`, `102`, `105`, and `109`.

It does not install DKMS drivers, replace host libraries, flash firmware, or
implement an autonomous RDMA validator. Infrastructure provisions the runtime
team's stack first. The validation Pods exercise actual VF allocation and
provide a place to run inter-node tests.

## Files and rendering

`deployment/bertha/values.yaml` is an environment values overlay.
`node-policies.yaml`, `pool-config.yaml`, `network.yaml`, and
`validation-pod.yaml` are Helm template strings, **not manifests to pass directly
to kubectl**. The existing chart evaluates them through `extraDeploy`; no
company-specific controller is required. The shared template preserves the
newline after each YAML document separator, including when the supplied
template trims its own leading whitespace.

From the repository root, use Bash and set up these arguments once:

```bash
CHART=./deployment/sriov-network-operator-chart
PROFILE=./deployment/bertha
CTX=kubernetes-admin@bertha-k8s-context
KCFG="$HOME/.kube/config-bertha"
NS=sriov-network-operator
SITE=/absolute/path/to/your/bertha-site-values.yaml

ARGS=(
  -f "$PROFILE/values.yaml"
  -f "$SITE"
  --set-file "extraDeploy[0]=$PROFILE/node-policies.yaml"
  --set-file "extraDeploy[1]=$PROFILE/pool-config.yaml"
  --set-file "extraDeploy[2]=$PROFILE/network.yaml"
  --set-file "extraDeploy[3]=$PROFILE/validation-pod.yaml"
)
```

Create the site values file at your chosen path before running these commands.
Keep it for subsequent upgrades. Do not omit any of the four `--set-file`
arguments, replace `extraDeploy` elsewhere, or use `--reuse-values` to carry
unreviewed settings forward.

## Infrastructure handoff

Use the runtime installation instructions in
`~/workspace/hyperaccel-sdk/communication/tools/rnic/README.md` and
`broadcom/install/install_broadcom_rdma.sh` under that directory.
The inspected baseline is:

- Ubuntu 22.04, with DKMS and headers matching the **running** kernel.
- `bnxt_en` version `1.10.3-233.0.152.2`, `bnxt_re` and the Broadcom userspace
  provider version `233.0.152.2`, from bundle `233.1.135.7`.
- Compatible rdma-core/libibverbs and the Broadcom provider in the directory
  actually searched by libibverbs.
- Correct board firmware, RDMA enabled, and SR-IOV available on both RNIC PFs.
- Host-level runtime `make check` and functional RDMA tests completed against
  the intended Thor 2 devices, not merely the first Broadcom devices found.

The four nodes were observed on `5.15.0-198-generic`. This profile neither
upgrades the kernel nor assumes an old `-139` or `-176` module can be reused.
Existing Broadcom Ethernet NICs share `bnxt_en`, so driver replacement remains
a host maintenance operation even when VF policy selectors are narrow.

Collect the real PF device ID, VF device ID, two PF PCI addresses per node,
`sriov_totalvfs`, firmware and interface names. Do not copy the existing
`1750/1806` mapping or the existing 10G NIC addresses as Thor 2 values.
The profile rejects known existing NIC IDs `16d6`, `16d7`, and `1657`.

## Site values and bootstrap

Set `images.*` to explicit, tested tags or digests in the site file. All image
entries in the common chart must be pinned; untagged images and `:latest`
are rejected by the profile. Keep operator, daemon and webhook images aligned
with the source/chart revision and use compatible CNI and device-plugin images.
The profile does not guess a release or publish a container image.

All nodes, the network and validation Pods are disabled by default. With pinned
images, the bootstrap render contains no node policies, SriovNetwork or test
Pods. It does include the operator configuration and a pool with
`maxUnavailable: 1`. The daemon selector requires both:

```text
hyperaccel.ai/thor2-planned=true
hyperaccel.ai/thor2-config=enabled
```

Keep the second label absent during bootstrap. Before installation, confirm
there are no matching nodes and no existing SR-IOV operator managing them:

```bash
kubectl --kubeconfig="$KCFG" --context="$CTX" get nodes \
  -l hyperaccel.ai/thor2-planned=true,hyperaccel.ai/thor2-config=enabled
helm lint "$CHART" --strict --kube-version 1.36.4 "${ARGS[@]}"
helm template sriov-network-operator "$CHART" \
  -n "$NS" --kube-version 1.36.4 "${ARGS[@]}"
```

An initial render without pinned images is expected to fail. Lint/render is
local validation, not proof that images can be pulled or hardware works.
The profile and shared document-boundary regression checks run without a
cluster using `bash test/scripts/bertha_helm_test.sh`; all addresses, device IDs
and images in that script are render-only fixtures.

After reviewing the output, install explicitly into the Bertha context:

```bash
kubectl --kubeconfig="$KCFG" --context="$CTX" create namespace "$NS"
kubectl --kubeconfig="$KCFG" --context="$CTX" label namespace "$NS" \
  pod-security.kubernetes.io/enforce=privileged
helm upgrade --install sriov-network-operator "$CHART" \
  --kubeconfig="$KCFG" --kube-context="$CTX" \
  -n "$NS" "${ARGS[@]}" --wait --timeout 10m
```

Skip namespace creation if it already exists. Multus and cert-manager already
exist in the observed cluster; do not reinstall them. The existing NAD CRD is
not a reason to use `--skip-crds`: the SR-IOV CRDs still need installation.

## Activate one node at a time

First add the verified mapping to the site file's `supportedExtraNICs` list.
Each list item is a YAML string with the structure
`Broadcom_BCM57608: "14e4 PF_ID VF_ID"`, where both IDs are four lowercase
hexadecimal digits obtained from the hardware/vendor data. Set
`bertha.deviceID` to the same PF ID. These are required site inputs, not
literal values to copy.

Under `bertha.nodes.bertha-xlarge-101`, set `enabled: true` and put exactly two
distinct PF PCI addresses in `rootDevices`. Leave the other nodes disabled.
Do not use `vendor: 14e4` alone, broad device-name matching, or an empty PCI
allowlist. The template fixes `numVfs: 1`, `deviceType: netdevice`,
`isRdma: true`, `linkType: eth`, and `externallyManaged: false`.
Infrastructure installing drivers does not make VFs externally managed.

Render and upgrade using the same arguments. If support IDs changed after
bootstrap, restart the operator, config daemon and webhook Pods after the
ConfigMap update: the NIC ID map is loaded at process startup, not treated as
a live configuration update. Discover the actual Deployment names with
`kubectl get deployment -n "$NS"` rather than assuming a Helm fullname.

Then label only the validated first node:

```bash
kubectl --kubeconfig="$KCFG" --context="$CTX" label node bertha-xlarge-101 \
  hyperaccel.ai/thor2-planned=true hyperaccel.ai/thor2-config=enabled
kubectl --kubeconfig="$KCFG" --context="$CTX" -n "$NS" \
  get sriovnetworknodestate bertha-xlarge-101 -o yaml
kubectl --kubeconfig="$KCFG" --context="$CTX" get node bertha-xlarge-101 \
  -o 'jsonpath={.status.capacity.hyperaccel\.ai/bertha_rnic}{"\n"}{.status.allocatable.hyperaccel\.ai/bertha_rnic}{"\n"}'
```

Require successful node-state synchronization, exactly the two intended PFs
in `spec.interfaces`, one VF per PF, and healthy resource capacity/allocatable
of two. `status.interfaces` may discover other NICs; discovery is not selection.
Compare existing NIC MTU, VF count and driver binding with the pre-change
inventory. Expand to 102 and 109 after this passes. Treat 105 separately because
it is a control-plane node. The pool limits operator updates to one unavailable
node; it is not a maintenance coordinator for external driver/firmware work.

Disabling a previously managed node/policy is **not** a harmless pause: policy
removal can reset VFs. Do not remove labels, disable nodes, uninstall the release
or reduce policies with live consumers without a planned teardown.

## Static validation network

This is an explicit-address test network, not production IP address management.
Confirm `/opt/cni/bin/static` exists on each target node; the SR-IOV operator
does not install that IPAM binary. Reserve distinct addresses on the real RNIC
subnet and confirm switch/VLAN/MTU connectivity with infrastructure.
Do not use host-local with an identical allocation range independently on all
nodes. A future production IPAM design is separate from this test profile.

Create `bertha.network.namespace` (default `bertha-rdma-test`) first. Set
`bertha.network.enabled: true`, the real `vlan` if needed, and keep
`network.ipam.type: static`. Render and upgrade, then require the generated NAD:

```bash
kubectl --kubeconfig="$KCFG" --context="$CTX" create namespace bertha-rdma-test
kubectl --kubeconfig="$KCFG" --context="$CTX" -n "$NS" \
  get sriovnetwork bertha-rdma -o yaml
kubectl --kubeconfig="$KCFG" --context="$CTX" -n bertha-rdma-test \
  get network-attachment-definition bertha-rdma -o yaml
```

The network and policy both use `bertha_rnic`. The profile does not force a
host-wide RDMA namespace-mode change or add an RDMA CNI chain implicitly.
Validate device visibility on this exact Broadcom stack before changing either.

## Validation Pods

The test image must contain the runtime-compatible libibverbs and Broadcom
provider, plus `ip`, `ibv_devinfo`, `rping`, a POSIX shell, `readlink` and `tail`.
It must not run the host installer on startup. Host libraries are not
automatically installed inside a workload image.

Set `bertha.validation.image` to a pinned image. In
`bertha.validation.nodes`, set reserved IPv4 CIDR addresses for at least two
enabled nodes (default names: 101 and 102), then enable validation. The generated
Pods request/limit one `hyperaccel.ai/bertha_rnic` each, attach the NAD as
`net1`, and pass their reserved addresses through the Multus annotation.
Registry pull secrets, if used, must exist in the test namespace as well.

Each Pod verifies `net1` is a VF and opens the RDMA device whose sysfs device
belongs to that VF, rather than accepting any Broadcom HCA on the node. On
success it logs `RDMA_READY` and remains running for manual communication
tests. A Running Pod alone is not a successful validation result.

```bash
kubectl --kubeconfig="$KCFG" --context="$CTX" -n bertha-rdma-test \
  logs -f thor2-check-bertha-xlarge-101
kubectl --kubeconfig="$KCFG" --context="$CTX" -n bertha-rdma-test \
  logs -f thor2-check-bertha-xlarge-102
```

After both log `RDMA_READY`, in one terminal run the server, substituting the
reserved net1 address of the 102 Pod **without** its prefix:

```bash
kubectl --kubeconfig="$KCFG" --context="$CTX" -n bertha-rdma-test \
  exec -it thor2-check-bertha-xlarge-102 -- rping -s -a "$SERVER_VF_IP" -v
```

When the server is listening, use another terminal for the finite client test:

```bash
kubectl --kubeconfig="$KCFG" --context="$CTX" -n bertha-rdma-test \
  exec -it thor2-check-bertha-xlarge-101 -- \
  rping -c -a "$SERVER_VF_IP" -C 10 -V -v
```

Use only the reserved VF-network address, not the Pod's primary Cilium IP.
Record successful validated transfers; device enumeration alone does not prove
communication. Stop the server after testing. These are CPU-memory RDMA tests,
not proof of Bertha peer-memory DMA or 400G throughput.

Each test Pod consumes one of the node's two VFs. With one VF per PF, requesting
two VFs can consume both physical RNICs, but this asset deliberately attaches
one VF per Pod. Check both PFs in the node state; a one-Pod test does not prove
both physical links.

Pod networking and many Pod spec fields are immutable. To change test addresses
or attachments, disable **only validation**, upgrade to remove the test Pods,
then re-enable it with the new values and upgrade again. This releases test VFs
without deleting node policies. Keep node/network activation separate from
test-Pod cleanup.
