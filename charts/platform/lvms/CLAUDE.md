# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A Helm chart that installs the LVM Storage (LVMS) operator standalone on OpenShift via OLM, plus an `LVMCluster` instance. It is one chart in a collection of per-component charts under `popai-helm-charts/` (catalog-sources, gpu, istio, nfd, nmstate-rdma, etc.), deployed through Argo CD.

## Commands

```bash
helm lint .                          # lint the chart
helm template test .                 # render all templates locally
helm template test . --values <file> # render with a per-cluster values override
```

There are no tests or CI in this repo; `helm lint` + `helm template` is the verification loop.

## Architecture

The chart renders four resources, ordered by Argo CD sync-waves (annotated on each template):

1. `templates/namespace.yaml` (wave 1) — Namespace, conditional on `namespace.create`
2. `templates/operatorgroup.yaml` (wave 2) — OperatorGroup scoping OLM to `targetNamespaces`
3. `templates/subscription.yaml` (wave 3) — Subscription pinning the operator channel/source/startingCSV
4. `templates/lvmcluster.yaml` (wave 4, gated by `lvmCluster.enabled`) — the `LVMCluster` CR the operator reconciles; `SkipDryRunOnMissingResource=true` because the CRD doesn't exist until the operator installs

The ordering matters: namespace → OperatorGroup → Subscription → LVMCluster is a hard dependency chain — the LVMCluster CRD only exists after OLM installs the operator from the Subscription.

Helpers in `templates/_helpers.tpl`: `lvms.labels` (standard Helm labels) and `lvms.namespace` (all resources land in `.Values.namespace.name`, even though the Subscription has its own `namespace` value — they should agree).

### Version pinning

`Chart.yaml` version, `subscription.channel` (stable-4.22), `subscription.startingCSV`, and the catalog `source` (cs-operator-index-4-22) are all pinned to the same minor (4.22). When bumping versions, update all of them together.

### Per-cluster overrides

`values.yaml` defaults are a generic starting point; cluster-specific settings — `deviceSelector.paths`, `deviceSelector.forceWipeDevicesAndDestroyAllData`, and `nodeSelector` (e.g. scoping to a RoCE worker pool) — are meant to be overridden per cluster via `mces/<mce>/<cluster>/lvms/values.yaml` (outside this repo). Keep cluster-specific values out of the defaults.

The thin-pool config (`lvmCluster.thinPool`) is global across all deviceClasses and mirrors the live 4.22 cluster (thin provisioning, 90% size, overprovision ratio 10). Setting `thinPool.enabled: false` switches to thick provisioning.
