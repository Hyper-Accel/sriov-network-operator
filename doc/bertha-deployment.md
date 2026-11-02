# Bertha Thor 2 deployment

This profile uses the existing operator chart. It creates **one VF per PF** on
two explicitly selected Broadcom BCM957608-P1400GDF00 PFs per enabled node.
The expected healthy capacity is `hyperaccel.ai/bertha_rnic: 2` per node, or
eight VFs across `bertha-xlarge-101`, `102`, `105`, and `109`.

For the completed node101 Pod allocation and VF-to-VF functional tests after
the NVM change and reboot, see
[the 2026-11-02 validation record](bertha-node101-validation.md).

It does not install DKMS drivers, replace host libraries, flash firmware, or
implement an autonomous RDMA validator. Infrastructure provisions the runtime
team's stack first. Test workloads and their network configuration are managed
separately; they are not shipped as part of this profile.

The profile keeps the policy validation webhook enabled through
`operator.admissionControllers.enabled: true`, but disables the network
resources injector with `sriovOperatorConfig.enableInjector: false`.
Workload creators must supply both the Multus network attachment annotation
and explicit VF resource requests/limits; the annotation alone does not reserve
a VF. This includes future portal-generated LaaS or vLLM workloads.

The injector override is optional in the shared chart. When omitted,
`enableInjector` continues to follow `operator.admissionControllers.enabled`;
an explicit `false` disables only the injector, not the policy webhook.

## Files and rendering

`deployment/bertha/values.yaml` is an environment values overlay.
`node-policies.yaml` and `pool-config.yaml` are Helm template strings,
**not manifests to pass directly to kubectl**. The existing chart evaluates
them through `extraDeploy`; no
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
)
```

Create the site values file at your chosen path before running these commands.
Keep it for subsequent upgrades. Do not omit either of the two `--set-file`
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
- **RDMA SR-IOV enabled separately from PF RDMA.** On niccli 233.0.150.0,
  `support_rdma=True` and `enable_sriov=Enabled` are not sufficient:
  `disable_rdma_sriov` must be `False` for the selected PF.
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

All nodes are disabled by default. With pinned images, the bootstrap render
contains no node policies. The profile does not create a SriovNetwork or test
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
cluster using `bash test/scripts/bertha_helm_test.sh`. The tests use render-only
images and synthetic hardware fixtures, and also check the verified node101
defaults without contacting the cluster.

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

The base values now contain node101's verified mapping, `14e4 1760 1819`,
and PF addresses `0000:4a:00.0` and `0000:c8:00.0`. Node101 remains disabled
in the base profile. Activate it through your site values file and additionally
set `sriovOperatorConfig.configDaemonNodeSelector.kubernetes.io/hostname`
to `bertha-xlarge-101` for a first-node rollout. Leave other nodes disabled.

For other hardware, add its verified mapping to `supportedExtraNICs`.
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

During the node101-only validation phase, this profile sets
`sriovOperatorConfig.disableDrain: true`. The validation Pod has been removed;
confirm no VF consumers remain before each device configuration change.
Revisit this setting before introducing production VF workloads. It skips
automatic drain rather than postponing device changes, and does not disable
reboots. Changes requiring node drain or reboot belong in the agreed
after-hours maintenance window.

`bertha.mtu` sets the policy's Ethernet MTU and defaults to **4200**, matching
the infrastructure PF baseline intended for RoCE active MTU **4096**.
Infrastructure reports MTU **9100** on all eight Thor 2 switch ports (two per
node on 101, 102, 105 and 109). That accommodates the 4200 host setting; it does
not require raising host MTU to 9100. Override `bertha.mtu` in site values only
when changing the agreed host/network configuration.

The operator applies this MTU to the selected netdevice VFs and raises a
selected PF's MTU if it is smaller than the requested value; it does not lower
a larger PF MTU. After deployment, verify VF Ethernet MTU with `ip link` and
RDMA `active_mtu` with `ibv_devinfo` on both allocated VFs. The initial node101
tests used Ethernet MTU 1500 / RDMA MTU 1024. A separate
[node101 follow-up](bertha-node101-validation.md#mtu-4200-follow-up---2026-11-02)
verified Ethernet MTU 4200 / RDMA MTU 4096 on both VFs and successful WRITE,
READ and payload-integrity tests. Other nodes remain unvalidated.

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

## Workload networking and historical test releases

Manage workload SriovNetwork/NAD and IPAM configuration separately, using the
policy's `bertha_rnic` resource. This profile does not force a host-wide RDMA
namespace-mode change or add an RDMA CNI chain implicitly.

The node101 test overlays, network, Pod template and image build file are no
longer shipped. Their observed setup, commands and results are retained in
[the validation record](bertha-node101-validation.md).

Repository cleanup does not change the installed Helm release. Before upgrading
a release that previously included those test resources, preserve its active
node selections and pinned images in your site values, inspect its existing
manifest, and review the removal of the Helm-managed test Pod and SriovNetwork.
Do not apply the disabled base defaults over an active deployment.

## RDMA SR-IOV firmware prerequisite

The initial node101 activation successfully created VF `0000:4b:00.0` under
PF `0000:4a:00.0` and VF `0000:c9:00.0` under PF `0000:c8:00.0`, both with
device ID `1819` and driver `bnxt_en`. However, both RNICs still reported
`disable_rdma_sriov=True`. Only the two PF RDMA devices existed; neither VF
had an RDMA auxiliary device. Consequently the device plugin correctly
excluded both VFs with `isRdma: true` and did not advertise the RDMA resource.

Check this option independently on each card before activation. The syntax
below was verified against the installed niccli 233.0.150.0:

```bash
niccli -pci 0000:4a:00.0 nvm -getoption support_rdma -scope 0
niccli -pci 0000:4a:00.0 nvm -getoption disable_rdma_sriov -scope 0
niccli -pci 0000:c8:00.0 nvm -getoption disable_rdma_sriov -scope 0
niccli -pci 0000:4a:00.0 nvm -optionhelp disable_rdma_sriov
```

The option help identifies it as a per-PF RoCE SR-IOV setting and requires
at least three MSI-X vectors per VF. Infrastructure must set it to `0`
(`False`) on the two RNIC PFs and arrange the supported apply/reset procedure.
The NVM write commands for that maintenance operation are:

```bash
niccli -pci 0000:4a:00.0 nvm -setoption disable_rdma_sriov -scope 0 -value 0
niccli -pci 0000:c8:00.0 nvm -setoption disable_rdma_sriov -scope 0 -value 0
```

These commands were not run during the initial operator deployment.
The query/help output does not establish whether this firmware can apply the
change live. Do not assume a VF rebind, PF reset or host reboot is harmless or
interchangeable, and do not unload the shared bnxt drivers on a live node.
The profile deliberately does not mutate NVRAM or reset adapters.

After the setting takes effect, require RDMA devices for both VFs, not just
the PFs. If the device plugin was started while no VF RDMA devices existed,
restart its node101 Pod after host discovery is correct so it rescans devices.
Never change `isRdma` to `false` merely to make the resource count appear:
Ethernet VF availability is not RDMA readiness.
