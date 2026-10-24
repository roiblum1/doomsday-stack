# aigw-ui deployments

The models aigw-ui deploys with Argo CD. Unlike the rest of this export,
this directory is live: Argo CD on the hub cluster reads it.

| Path | Who writes it | What |
|---|---|---|
| `deployments/<cluster>/<name>.yaml` | aigw-ui (Deployments page), or a person | One model on one cluster: the values of `charts/model-deployer`, plus `deployment.cluster` and `deployment.namespace` |
| `presets/<preset>.yaml` | People | Starting points the Deployments page offers. `preset.title` and `preset.description` are left out of a deployment |
| `bootstrap/` | People, once per Argo CD | The AppProject, the ApplicationSet, an example cluster Secret, and the read-only Role for aigw-ui's status column |

aigw-ui reads the files back, so a change made by hand shows on its page.
It rewrites a file only when someone saves that deployment there, and then
writes it without comments, keys in alphabetical order.

## Setting it up

1. On each serving cluster, an account for Argo CD; on the hub, its cluster
   Secret with `project: aigw-ui-models` and the cluster's name in aigw-ui
   (`bootstrap/cluster-secret.example.yaml`).
2. `oc apply -f bootstrap/appproject.yaml -f bootstrap/applicationset.yaml`
3. Optional: `oc apply -f bootstrap/hub-status-role.yaml` and the hub's
   `gitops.argocdNamespace`.
4. The hub's `gitops.*` values: this repository, the branch, the directory
   `gitops/aigw-ui`, and a key or token that may push.

## What happens on a change

1. aigw-ui commits the file (one commit per change, by the admin's action).
2. Within 30 s the ApplicationSet creates the Application of a new file;
   an existing Application picks up a change at its next refresh (3 min,
   at once with a webhook from the git server to Argo CD).
3. Argo CD renders the chart with the file and applies it: PVC and download
   Job first (wave −1), then the model.
4. aigw-ui's discovery finds the model on the cluster (its peer route) and
   lists it under Models.

Removing a file deletes the Application and what it deployed, except the
weights PVC (`Delete=false`).
