#!/usr/bin/env bash

set -o pipefail
SCRIPTPATH="$(cd -- "$(dirname "$0")" && pwd -P)"
ROOT="$(cd "$SCRIPTPATH/../.." && pwd -P)"
CHART="$ROOT/deployment/sriov-network-operator-chart"
PROFILE="$ROOT/deployment/bertha"

# Render-only fixtures. These are not verified hardware IDs or usable images.
IMAGES='{
  "operator":"registry.invalid/operator:render-test",
  "sriovConfigDaemon":"registry.invalid/daemon:render-test",
  "sriovCni":"registry.invalid/sriov-cni:render-test",
  "ibSriovCni":"registry.invalid/ib-cni:render-test",
  "ovsCni":"registry.invalid/ovs-cni:render-test",
  "rdmaCni":"registry.invalid/rdma-cni:render-test",
  "sriovDevicePlugin":"registry.invalid/device-plugin:render-test",
  "resourcesInjector":"registry.invalid/injector:render-test",
  "webhook":"registry.invalid/webhook:render-test",
  "metricsExporter":"registry.invalid/exporter:render-test",
  "metricsExporterKubeRbacProxy":"registry.invalid/proxy:render-test"
}'
ONE_NODE='{"bertha-xlarge-101":{"enabled":true,"rootDevices":["0000:81:00.0","0000:a1:00.0"]}}'
FOUR_NODES='{
  "bertha-xlarge-101":{"enabled":true,"rootDevices":["0000:81:00.0","0000:a1:00.0"]},
  "bertha-xlarge-102":{"enabled":true,"rootDevices":["0000:82:00.0","0000:a2:00.0"]},
  "bertha-xlarge-105":{"enabled":true,"rootDevices":["0000:83:00.0","0000:a3:00.0"]},
  "bertha-xlarge-109":{"enabled":true,"rootDevices":["0001:84:00.0","0001:a4:00.0"]}
}'

renderBertha() {
    helm template bertha-test "$CHART" -n sriov-network-operator \
        --kube-version 1.36.4 -f "$PROFILE/values.yaml" \
        --set-file "extraDeploy[0]=$PROFILE/node-policies.yaml" \
        --set-file "extraDeploy[1]=$PROFILE/pool-config.yaml" \
        --set-json "images=$IMAGES" \
        --set-string bertha.deviceID=abcd \
        --set-json 'supportedExtraNICs=["RenderOnly: \"14e4 abcd abce\""]' \
        --show-only templates/extra-list.yaml "$@"
}

test_ExtraDeploy_Object_And_Template_Document_Boundaries() {
    local output status
    output=$(helm template boundary-test "$CHART" \
        --set-json 'extraDeploy=[{"apiVersion":"v1","kind":"ConfigMap","metadata":{"name":"object"}},"{{- /* Trimmed external template */ -}}\napiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: {{ .Release.Name }}"]' \
        --show-only templates/extra-list.yaml 2>&1)
    status=$?
    assertEquals "$output" 0 "$status"
    assertEquals "2" "$(printf '%s\n' "$output" | awk '$0 == "apiVersion: v1" {n++} END {print n+0}')"
    assertNotContains "$output" "---apiVersion"
    assertContains "$output" "name: boundary-test"
}

test_Bootstrap_Has_No_Policies_Network_Or_Pods() {
    local output status
    output=$(renderBertha 2>&1)
    status=$?
    assertEquals "$output" 0 "$status"
    assertContains "$output" "kind: SriovNetworkPoolConfig"
    assertEquals "0" "$(printf '%s\n' "$output" | awk '$0 == "kind: SriovNetworkNodePolicy" || $0 == "kind: SriovNetwork" || $0 == "kind: Pod" {n++} END {print n+0}')"
    assertNotContains "$output" "---apiVersion"
}

test_Exactly_One_VF_Per_PF_On_All_Four_Nodes() {
    local output status
    output=$(renderBertha --set-json "bertha.nodes=$FOUR_NODES" 2>&1)
    status=$?
    assertEquals "$output" 0 "$status"
    assertEquals "4" "$(printf '%s\n' "$output" | awk '$0 == "kind: SriovNetworkNodePolicy" {n++} END {print n+0}')"
    assertEquals "4" "$(printf '%s\n' "$output" | awk '$1 == "numVfs:" && $2 == "1" {n++} END {print n+0}')"
    assertEquals "4" "$(printf '%s\n' "$output" | awk '$1 == "mtu:" && $2 == "4200" {n++} END {print n+0}')"
    assertEquals "4" "$(printf '%s\n' "$output" | awk '$1 == "externallyManaged:" && $2 == "false" {n++} END {print n+0}')"
    assertContains "$output" 'kubernetes.io/hostname: "bertha-xlarge-105"'
    assertContains "$output" "0001:84:00.0"
    assertContains "$output" "maxUnavailable: 1"
}

test_MTU_Override_Applies_To_All_Enabled_Node_Policies() {
    local output status
    output=$(renderBertha --set-json "bertha.nodes=$FOUR_NODES" \
        --set bertha.mtu=9000 2>&1)
    status=$?
    assertEquals "$output" 0 "$status"
    assertEquals "4" "$(printf '%s\n' "$output" | awk '$1 == "mtu:" && $2 == "9000" {n++} END {print n+0}')"
    assertEquals "0" "$(printf '%s\n' "$output" | awk '$1 == "mtu:" && $2 != "9000" {n++} END {print n+0}')"
}

test_One_Node_Can_Be_Activated_Independently() {
    local output status
    output=$(renderBertha --set-json "bertha.nodes=$ONE_NODE" 2>&1)
    status=$?
    assertEquals "$output" 0 "$status"
    assertEquals "1" "$(printf '%s\n' "$output" | awk '$0 == "kind: SriovNetworkNodePolicy" {n++} END {print n+0}')"
    assertNotContains "$output" "thor2-bertha-xlarge-105"
}

test_Activation_Rejects_Missing_Or_Duplicate_PFs() {
    local output
    output=$(renderBertha --set bertha.nodes.bertha-xlarge-101.enabled=true \
        --set-json 'bertha.nodes.bertha-xlarge-101.rootDevices=[]' 2>&1)
    assertNotEquals "$output" 0 "$?"
    output=$(renderBertha --set-json 'bertha.nodes={"bertha-xlarge-101":{"enabled":true,"rootDevices":["0000:81:00.0","0000:81:00.0"]}}' 2>&1)
    assertNotEquals "$output" 0 "$?"
}

test_Activation_Rejects_Invalid_PCI_Address() {
    local output
    output=$(renderBertha --set-json 'bertha.nodes={"bertha-xlarge-101":{"enabled":true,"rootDevices":["0000:81:ff.0","0000:a1:00.0"]}}' 2>&1)
    assertNotEquals "$output" 0 "$?"
}

test_Activation_Requires_Matching_PF_VF_Map() {
    local output
    output=$(renderBertha --set-json "bertha.nodes=$ONE_NODE" --set-json 'supportedExtraNICs=[]' 2>&1)
    assertNotEquals "$output" 0 "$?"
    output=$(renderBertha --set-json "bertha.nodes=$ONE_NODE" --set-string bertha.deviceID=dcba 2>&1)
    assertNotEquals "$output" 0 "$?"
}

test_Existing_NICs_And_Unknown_Nodes_Are_Rejected() {
    local output
    output=$(renderBertha --set-json "bertha.nodes=$ONE_NODE" --set-string bertha.deviceID=16d7 2>&1)
    assertNotEquals "$output" 0 "$?"
    output=$(renderBertha --set-json 'bertha.nodes={"bertha-xlarge-103":{"enabled":true,"rootDevices":["0000:81:00.0","0000:a1:00.0"]}}' 2>&1)
    assertNotEquals "$output" 0 "$?"
}

test_Untagged_And_Latest_Images_Are_Rejected() {
    local output
    output=$(renderBertha --set-string images.operator=registry.invalid/operator 2>&1)
    assertNotEquals "$output" 0 "$?"
    output=$(renderBertha --set-string images.operator=registry.invalid/operator:latest 2>&1)
    assertNotEquals "$output" 0 "$?"
}

test_Verified_Node101_Policy_Is_Narrowly_Selected() {
    local output status
    output=$(helm template bertha-test "$CHART" -n sriov-network-operator \
        -f "$PROFILE/values.yaml" --set-json "images=$IMAGES" \
        --set bertha.nodes.bertha-xlarge-101.enabled=true \
        --set-file "extraDeploy[0]=$PROFILE/node-policies.yaml" \
        --set-file "extraDeploy[1]=$PROFILE/pool-config.yaml" 2>&1)
    status=$?
    assertEquals "$output" 0 "$status"
    assertEquals "1" "$(printf '%s\n' "$output" | awk '$0 == "kind: SriovNetworkNodePolicy" {n++} END {print n+0}')"
    assertContains "$output" 'Broadcom_BCM57608: "14e4 1760 1819"'
    assertContains "$output" 'deviceID: "1760"'
    assertContains "$output" "0000:4a:00.0"
    assertContains "$output" "0000:c8:00.0"
    assertContains "$output" 'kubernetes.io/hostname: "bertha-xlarge-101"'
    assertNotContains "$output" "thor2-bertha-xlarge-102"
    assertNotContains "$output" "thor2-bertha-xlarge-105"
    assertNotContains "$output" "thor2-bertha-xlarge-109"
    assertEquals "0" "$(printf '%s\n' "$output" | awk '$0 == "kind: SriovNetwork" || $0 == "kind: Pod" {n++} END {print n+0}')"
}

source "$SCRIPTPATH/shunit2"
