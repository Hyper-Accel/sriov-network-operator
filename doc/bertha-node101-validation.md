# Node101 VF RDMA validation - 2026-11-02

## MTU 4200 follow-up - 2026-11-02

The follow-up applied `bertha.mtu: 4200` to **node101 only**. Infrastructure
reported switch MTU 9100 on the eight Thor 2 ports; host PF MTU remained 4200.
Nodes102/105/109 were not activated or tested because their RDMA cabling was
not ready. The earlier 1500/1024 results below are retained as a separate run.

### Application without node drain

Changing existing VF MTU normally requests a full node drain in this operator.
With the user's approval, the existing validation Pod was removed first and
both VFs were confirmed back in the host with no remaining VF consumers.
`disableDrain` was temporarily set to `true`, and the daemon's receipt of that
setting was confirmed before updating the policy. The operator then configured
both VFs to MTU 4200. No node drain, reboot, PDB change or unrelated workload
eviction was performed.

After successful reconciliation, `disableDrain: false` was restored and the
primary validation Pod was recreated. Helm revision **7** was deployed, with
the original image digests, node101-only daemon selector and test network
preserved. Node state generation 3 reported `Succeeded`, no sync error and
Ready; node101 remained schedulable and advertised two VF resources. The
management default route remained on `ens3f0.120`.

This was a controlled change with both VFs unused, not a recommendation to
disable drain for arbitrary policy changes. Changes requiring an actual node
drain or reboot are deferred to an after-hours maintenance window.

### Hardware and communication results

Both Pods ran on node101. Allocation order changed from the earlier run:

| Role | Allocated VF | RDMA device | Ethernet MTU | RDMA active MTU | Port state |
| --- | --- | --- | --- | --- | --- |
| Primary/server | `0000:4b:00.0` | `bnxt_re0` | 4200 | 4096 | ACTIVE |
| Temporary peer/client | `0000:c9:00.0` | `bnxt_re1` | 4200 | 4096 | ACTIVE |

The primary Pod's Cilium IP was `10.245.0.156`; the peer's was `10.245.0.222`.
Both Multus network-status annotations and `ip link show net1` reported 4200.
`ibv_devinfo -v` reported active MTU 4096 and RoCE v2 at GID index 1 on both VFs.

| Test | Configuration | Result |
| --- | --- | --- |
| RDMA WRITE | MTU 4096, 4096 bytes, 1000 iterations, one RC QP | Both exit 0; average 113.32 Gb/s |
| RDMA READ | MTU 4096, 4096 bytes, 1000 iterations, one RC QP | Both exit 0; average 75.91 Gb/s |
| RDMA-CM payload validation | `rping`, `-S 4096` on both sides, client `-C 10 -V` | Both exit 0; exactly 10 validated payload records |

The perftest commands below were reused with `SERVER_DEV=bnxt_re0`,
`CLIENT_DEV=bnxt_re1`, the newly observed server IP and **`-m 4096` on both
endpoints** instead of `-m 1024`. The rping server used
`fe80::9c56:f8ff:fef7:b5ba%net1`; the client source was
`fe80::f03e:dfff:fe40:852e%net1`. Each server's LISTEN state was confirmed
before starting its client, and every process had a 90-second timeout.

These short runs verify functionality at the new MTU, not a throughput
improvement or 400G qualification. They do not validate the other nodes or
Bertha peer-memory DMA. The temporary peer was removed after testing; the
primary Pod remains for inspection and consumes one VF. No test deployment
files were reintroduced into the repository.

## Scope and result

Validated two Pods on **bertha-xlarge-101 only**, each allocated one VF from
a different BCM57608 RNIC. No changes were made to node102/105/109 activation,
host drivers, firmware, or physical interface settings during this validation.
No IPv4 addresses were assigned to the VFs.

After the infrastructure NVM change and the user's reboot, the node advertised
`hyperaccel.ai/bertha_rnic` capacity and allocatable of **2**. Both VFs were
reported Healthy by Kubernetes and their RDMA ports became ACTIVE when the
SR-IOV CNI attached and brought up `net1` in their respective Pods.

| Role | Pod | PF | Allocated VF | RDMA device |
| --- | --- | --- | --- | --- |
| Server | `thor2-check-bertha-xlarge-101` | `0000:c8:00.0` | `0000:c9:00.0` | `bnxt_re1` |
| Client | `thor2-check-bertha-xlarge-101-peer` | `0000:4a:00.0` | `0000:4b:00.0` | `bnxt_re0` |

The server's assigned device files included `uverbs3`; `net1` and its PCI/RDMA
mapping were verified rather than accepting an arbitrary host PF HCA.
The temporary peer was created from the same rendered validation Pod spec
and was not added to the Helm release.

This is a historical test record, not a deployable test profile. The temporary
node101 Helm overlays, test network and Pod templates, and validation-image
Dockerfile have been removed from the repository. The operator profile retains
only its node policies and pool configuration. Repository cleanup did not
upgrade the running Helm release or delete cluster resources.

## Recorded setup

- Ubuntu 22.04.5, kernel `5.15.0-198-generic`; `bnxt_en`
  `1.10.3-233.0.152.2`, `bnxt_re` and userspace provider `233.0.152.2`.
- Vendor/PF/VF IDs: `14e4:1760:1819`; one VF per selected PF.
- Infrastructure set `disable_rdma_sriov=False` on both cards. The user's
  reboot at **2026-11-02 10:07:39 KST** made both VF RDMA devices available.
- Only node101 was enabled, with the config daemon additionally selected by
  `kubernetes.io/hostname=bertha-xlarge-101`; nodes102/105/109 stayed inactive.
- Operator, daemon and webhook images matched upstream source commit
  `9163bcc7a8cbc4cfcb366c15ef5824ccfb30dab2`; deployed images were digest-pinned.
- The `bertha-rdma` SriovNetwork generated a NAD in `bertha-rdma-test`,
  using resource `bertha_rnic`, VLAN 0 and IPAM `{"type":""}`. Each Pod attached
  one VF as `net1` through Multus, requested and limited
  `hyperaccel.ai/bertha_rnic: 1`, and added `IPC_LOCK`. Pods were not privileged
  and did not use host networking.
- The validation image packaged rdma-core 39 and the Broadcom provider built
  from the runtime-provisioned host's
  `/usr/local/src/libbnxt_re-233.0.152.2`. The provider was installed at
  `/usr/lib/x86_64-linux-gnu/libibverbs/libbnxt_re-rdmav34.so`.
  It did not install or load host kernel modules.
- Each Pod checked that `/sys/class/net/net1/device/physfn` existed, matched
  the VF's sysfs path to its RDMA device, and successfully ran
  `ibv_devinfo -d DEVICE -v` before logging `RDMA_READY`.

## Functional tests

The image was
`cr.hyperaccel.net/hyperaccel/sriov-rdma-validation@sha256:d82c0d9dd01ef6e25effc7818229b93cfc228554b62bab4fda2af8896409c0c3`.
It contains the Broadcom 233.0.152.2 userspace provider, rdma-core 39 and
perftest 5.96. The Ethernet MTU was 1500; the active RDMA MTU was 1024.

| Test | Configuration | Result |
| --- | --- | --- |
| RDMA WRITE | 4096 bytes, 1000 iterations, one RC QP, RoCE v2 GID index 1 | Both processes exited 0; average 68.34 Gb/s |
| RDMA READ | 4096 bytes, 1000 iterations, one RC QP, RoCE v2 GID index 1 | Both processes exited 0; average 82.81 Gb/s |
| RDMA-CM payload validation | `rping`, 4096-byte buffers on both sides, 10 iterations, `-V` | Both processes exited 0; exactly 10 validated `ping data:` records |

The perftest TCP control connection used the Pods' Cilium IPs. The RDMA data
path used the explicitly selected VF devices and their RoCE v2 GIDs.
The rping test used the automatically generated IPv6 link-local addresses on
`net1`, including `%net1` scope identifiers. No reserved IPv4 address was guessed.

These are **functional results, not a 400G throughput qualification**.
Perftest reported CPU-frequency warnings, and the tests used only one QP and
short runs without NUMA/CPU tuning. VF `hw_counters/tx_bytes` and `rx_bytes`
were not exposed in these Pod sysfs views; no independent hardware-byte-counter
measurement is claimed. This does not validate cross-node fabric behavior,
production IPv4 IPAM, congestion behavior, or Bertha peer-memory DMA.

## Issues found and resolved

1. The first Pod obtained a Healthy VF and CNI attachment but could not pull
   the private validation image. A registry-scoped `harbor-secret` was provided
   in `bertha-rdma-test`, and the test Pod referenced it in `imagePullSecrets`.
   Operator and daemon image-pull settings were not changed. Registry
   credentials are not stored in this repository.
2. An initial rping invocation used a larger client buffer than the server
   default. The server failed its first RDMA READ with CQ status 4
   (`IBV_WC_LOC_PROT_ERR`). It was not a successful payload test, even though
   the disconnected client exited 0. Setting **`-S 4096` on both endpoints**
   resolved it. Always require the expected payload count and successful
   termination on both endpoints; client exit code alone is insufficient.

## Recorded test commands

These commands require an existing primary test Pod with the recorded setup
above; the repository no longer creates it. For a new run, provision the test
NAD, Pod and namespace-local registry Secret separately from the operator
release. The primary Pod must log `RDMA_READY`, and both VF resources must be
healthy before creating its peer. Operator deployment prerequisites are in
[bertha-deployment.md](bertha-deployment.md).

The following examples use Bash and jq:

```bash
K=(kubectl --kubeconfig "$HOME/.kube/config-bertha" \
  --context kubernetes-admin@bertha-k8s-context -n bertha-rdma-test)
SERVER=thor2-check-bertha-xlarge-101
CLIENT=thor2-check-bertha-xlarge-101-peer

# Create an unowned, temporary peer with the same spec, without copying runtime
# identity, network-status annotations, or the scheduler's assigned nodeName.
"${K[@]}" get pod "$SERVER" -o json | jq --arg name "$CLIENT" '
  .metadata = {
    name: $name,
    namespace: "bertha-rdma-test",
    labels: {
      "app.kubernetes.io/name": "bertha-rdma-validation",
      "app.kubernetes.io/component": "temporary-peer"
    },
    annotations: {
      "k8s.v1.cni.cncf.io/networks":
        .metadata.annotations["k8s.v1.cni.cncf.io/networks"]
    }
  } | del(.status, .spec.nodeName)
' | "${K[@]}" create -f -

"${K[@]}" wait --for=condition=Ready "pod/$CLIENT" --timeout=5m
"${K[@]}" logs "$CLIENT"
```

Require `RDMA_READY` in both Pods' logs. Inspect each Pod's
`k8s.v1.cni.cncf.io/network-status` annotation to determine the allocated PCI
address and RDMA device. Allocation order can change; do not assume which
Pod receives `bnxt_re0` on a later run.

For the recorded allocation:

```bash
SERVER_DEV=bnxt_re1
CLIENT_DEV=bnxt_re0
SERVER_IP=$("${K[@]}" get pod "$SERVER" -o jsonpath='{.status.podIP}')
```

Confirm GID index 1 is RoCE v2 on both devices with `ibv_devinfo -d DEVICE -v`.
Start the WRITE server in one terminal:

```bash
"${K[@]}" exec "$SERVER" -- timeout 90s stdbuf -oL -eL \
  ib_write_bw -d "$SERVER_DEV" -i 1 -x 1 -m 1024 \
  -s 4096 -n 1000 -p 18515 --report_gbits
```

Confirm the server is actually listening before running the client in another
terminal; do not substitute a fixed sleep:

```bash
"${K[@]}" exec "$SERVER" -- ss -H -ltn 'sport = :18515'
"${K[@]}" exec "$CLIENT" -- timeout 90s stdbuf -oL -eL \
  ib_write_bw "$SERVER_IP" -d "$CLIENT_DEV" -i 1 -x 1 -m 1024 \
  -s 4096 -n 1000 -p 18515 --report_gbits
```

For READ, use `ib_read_bw` on both endpoints and port 18516, retaining the
same explicit device, GID, MTU, size and iteration settings.

For payload integrity, inspect `ip -6 address show dev net1` in each Pod and
set `SERVER_V6` and `CLIENT_V6` to the observed link-local addresses with
`%net1` appended. In separate terminals:

```bash
"${K[@]}" exec "$SERVER" -- timeout 90s stdbuf -oL -eL \
  rping -s -a "$SERVER_V6" -p 18519 -S 4096 -V -d

# Require LISTEN on bnxt_re1 / the selected server VF before starting the client.
"${K[@]}" exec "$SERVER" -- rdma resource show cm_id
"${K[@]}" exec "$CLIENT" -- timeout 90s stdbuf -oL -eL \
  rping -c -I "$CLIENT_V6" -a "$SERVER_V6" \
  -p 18519 -C 10 -S 4096 -V -v
```

Verify ten payload records and both exit codes, then remove only the peer:

```bash
"${K[@]}" delete pod "$CLIENT" --wait=true --timeout=90s
```

At the end of the recorded run, the Helm-managed primary Pod remained for
inspection and consumed one VF; the temporary peer was deleted.
The released VF may return to administrative DOWN while remaining registered
as a valid RDMA device. Node capacity/allocatable describes total advertised
capacity, not the number currently unallocated.

Removing the source test templates does not remove that historical release's
resources immediately. A later Helm upgrade that omits them can delete its
test Pod and SriovNetwork; review that release change and its consumers before
applying it.
