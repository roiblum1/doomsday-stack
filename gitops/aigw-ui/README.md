# aigw-ui and the Argo CD platform

aigw-ui's Deployments page reads and writes `gitops/app-of-apps` in the
platform's layout (see that README). It writes three kinds of files, one
commit per save:

| File | Page action |
|---|---|
| `sites/<site>/<env>/mces/<mce>/<cluster>/<model>/values.yaml` | Deploy (the directory registers the model on the cluster), Edit (what differs on this cluster), Remove (the directory goes) |
| `operators/<model>/values.yaml` | Edit recipe (every cluster's first layer) |
| `operators/<model>/<model>.yaml` + `values.yaml` | New model (app config copied from an existing model) |

A model is an operator whose values have `model.name`; the others (gpu,
envoy-ai, ...) are left alone. aigw-ui reads every file back: a change made
by hand shows on its page.

## bootstrap/ (the lab only)

argocd-day2-platform is not in this export. On the lab's hub, an
ApplicationSet stands in for it for `sites/site-lab` only:

1. On the serving cluster, an account for Argo CD; on the hub, its cluster
   Secret with `project: aigw-ui-models` and the cluster's name in aigw-ui
   (`cluster-secret.example.yaml`).
2. `oc apply -f appproject.yaml -f applicationset.yaml`
3. Optional: `oc apply -f hub-status-role.yaml` and the hub's
   `gitops.argocdNamespace`: the page then shows each Application's sync and
   health.
4. The hub's `gitops.*` values: this repository, branch `main`, directory
   `gitops/app-of-apps`, and a Secret with a key that may push.

It names Applications as the platform does (`popai-<cluster>-<model>-deploy`),
layers the values the same way, and reads `chartPath` from the app config
(the lab's chart is in this repository; the platform's are not).
