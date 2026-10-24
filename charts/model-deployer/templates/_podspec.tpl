{{/* The pod spec of the model's pods: the leader (template) and, multi-node,
     the workers (worker). Called with (dict "ctx" . "worker" bool). Workers
     get no probes and no storage-initializer: the leader serves, and the
     weights come from a PVC on multi-node recipes. */}}
{{- define "md.podSpec" -}}
{{- $ := .ctx -}}
{{- $v := $.Values -}}
{{- $l := $v.llmisvc -}}
{{- $dp := $l.dataParallelExternalLB | default dict -}}
{{- $ranks := int ($dp.ranks | default 0) -}}
{{- with $v.serviceAccount.name }}
serviceAccountName: {{ . }}
{{- end }}
{{- with $l.runtimeClassName }}
runtimeClassName: {{ . }}
{{- end }}
{{- with $l.schedulerName }}
schedulerName: {{ . }}
{{- end }}
{{- with $l.terminationGracePeriodSeconds }}
terminationGracePeriodSeconds: {{ . }}
{{- end }}
{{- with $v.nodes.gpuProduct }}
nodeSelector:
  nvidia.com/gpu.product: {{ . }}
{{- end }}
{{- with $l.tolerations }}
tolerations:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- if and $l.storageInitializer.enabled (not .worker) }}
# Override for the controller-injected storage-initializer (s3:// or
# hf:// model URIs): the controller merges this patch -- image,
# resources and env here win, args/command stay the controller's.
initContainers:
  - name: storage-initializer
    {{- with ($l.storageInitializer.image | default $v.images.storageInitializer) }}
    image: {{ . }}
    imagePullPolicy: IfNotPresent
    {{- end }}
    {{- with $l.storageInitializer.home }}
    # The download writes its cache under $HOME, which is / and not
    # writable under OpenShift's random user ID.
    env:
      - name: HOME
        value: {{ . }}
      - name: HF_HOME
        value: {{ . }}/hf
    {{- end }}
    {{- with $l.storageInitializer.resources }}
    resources:
      {{- toYaml . | nindent 6 }}
    {{- end }}
{{- end }}
containers:
  - name: main
    {{- with $v.images.vllm }}
    image: {{ . }}
    imagePullPolicy: IfNotPresent
    {{- end }}
    args:
      {{- if gt $ranks 1 }}
      # Data parallel with one port per rank (8000, 8001, ...): the
      # scheduler picks a rank; the supervisor answers for all of them.
      - {{ printf "--data-parallel-size=%d" $ranks | quote }}
      - {{ printf "--data-parallel-size-local=%d" $ranks | quote }}
      - --data-parallel-multi-port-external-lb
      - {{ printf "--data-parallel-supervisor-port=%d" (int ($dp.supervisorPort | default 8208)) | quote }}
      {{- end }}
      {{- range $l.extraArgs }}
      - {{ . | toString | quote }}
      {{- end }}
      {{- range $l.args }}
      - {{ . | toString | quote }}
      {{- end }}
      {{- with $v.model.maxModelLen }}
      - {{ printf "--max-model-len=%v" . | quote }}
      {{- end }}
      {{- if $v.lmcache.enabled }}
      # --- LMCache: hand KV-cache ownership to the LMCacheMPConnector.
      # One JSON blob, compact (no spaces). It MUST be wrapped in single
      # quotes: the kserve preset launcher evals `vllm serve ... $@`, and
      # in that eval re-parse a bare {"a":"b","c":"d"} hits bash BRACE
      # EXPANSION (splits at the commas into words; quote removal then
      # eats the double quotes) -- vLLM received "kv_connector:..." and
      # died on json_invalid.
      - --kv-transfer-config
      - {{ printf "'%s'" (include "md.kvTransferConfig" $) | quote }}
      {{- end }}
    env:
      {{- range $key := keys ($l.env | default dict) | sortAlpha }}
      - name: {{ $key }}
        value: {{ index $l.env $key | toString | quote }}
      {{- end }}
      {{- with $l.keepAliveSeconds }}
      # vLLM closes a connection after this many idle seconds; with its
      # default of 5 the 3-second health checks met closing connections
      # and took the only site out (the 503 storm).
      - name: VLLM_HTTP_TIMEOUT_KEEP_ALIVE
        value: {{ . | toString | quote }}
      {{- end }}
      {{- if $l.roce }}
      # KServe's launcher finds the active RoCE HCAs and the GID index and
      # sets NCCL_IB_HCA, NVSHMEM_HCA_LIST, UCX_NET_DEVICES and the GID
      # index (a value set in env wins).
      - name: KSERVE_INFER_ROCE
        value: "true"
      {{- end }}
      {{- if $v.lmcache.enabled }}
      # Deterministic prefix hashing across vLLM processes and restarts
      # (the operator's webhook sets it on injected pods too).
      - name: PYTHONHASHSEED
        value: "0"
      # Skip deep_gemm's eager boot warmup (it allocates a max-M-sized
      # buffer after the KV pool is sized -- OOM risk; DeepGEMM's JIT
      # cache is persistent on the cache LV anyway, so kernels compile
      # on first use instead of at boot).
      - name: VLLM_DEEP_GEMM_WARMUP
        value: "skip"
      {{- end }}
    {{- with $l.resources }}
    resources:
      {{- toYaml . | nindent 6 }}
    {{- end }}
    {{- if $l.ipcLock }}
    # Root with IPC_LOCK (shared memory, hugepages, LMCache's CUDA IPC):
    # needs the chart's SCC (scc.create).
    securityContext:
      runAsNonRoot: false
      allowPrivilegeEscalation: false
      capabilities:
        add:
          - IPC_LOCK
    {{- end }}
    {{- $probes := $l.probes }}
    {{- if and (gt $ranks 1) $probes }}
    {{- /* The supervisor answers for every rank: /health while the process
           lives, /readyz once all ranks serve. */}}
    {{- $probes = merge (dict "port" (int ($dp.supervisorPort | default 8208)) "readiness" (merge (dict "path" "/readyz") $probes.readiness)) $probes }}
    {{- end }}
    {{- if and $probes (not .worker) }}
    # Probe target from values: port + per-probe path (DP multi-port
    # external LB recipes point at the supervisor's aggregated
    # /health + /readyz on --data-parallel-supervisor-port; internal-LB
    # and TP recipes at the API server on :8000 -- /readyz does not
    # exist there, use /health). Empty keeps KServe's own probes.
    startupProbe:
      httpGet:
        path: {{ $probes.startup.path }}
        port: {{ $probes.port }}
        scheme: HTTP
      periodSeconds: {{ $probes.startup.periodSeconds }}
      failureThreshold: {{ $probes.startup.failureThreshold }}
      timeoutSeconds: {{ $probes.startup.timeoutSeconds }}
    readinessProbe:
      httpGet:
        path: {{ $probes.readiness.path }}
        port: {{ $probes.port }}
        scheme: HTTP
      periodSeconds: {{ $probes.readiness.periodSeconds }}
      failureThreshold: {{ $probes.readiness.failureThreshold }}
      timeoutSeconds: {{ $probes.readiness.timeoutSeconds }}
    livenessProbe:
      httpGet:
        path: {{ $probes.liveness.path }}
        port: {{ $probes.port }}
        scheme: HTTP
      periodSeconds: {{ $probes.liveness.periodSeconds }}
      failureThreshold: {{ $probes.liveness.failureThreshold }}
      timeoutSeconds: {{ $probes.liveness.timeoutSeconds }}
    {{- end }}
    {{- if or $v.storage.cache.pvcName $l.volumes.hugepagesSize }}
    volumeMounts:
      {{- if $v.storage.cache.pvcName }}
      - mountPath: /cache
        name: compile-cache
      {{- end }}
      {{- if $l.volumes.hugepagesSize }}
      - mountPath: /dev/hugepages
        name: hugepages
      {{- end }}
    {{- end }}
{{- if or $v.storage.cache.pvcName $l.volumes.dshmSize $l.volumes.hugepagesSize }}
volumes:
  {{- if $l.volumes.dshmSize }}
  - name: dshm
    emptyDir:
      medium: Memory
      sizeLimit: {{ $l.volumes.dshmSize }}
  {{- end }}
  {{- if $l.volumes.hugepagesSize }}
  - name: hugepages
    emptyDir:
      medium: HugePages
      sizeLimit: {{ $l.volumes.hugepagesSize }}
  {{- end }}
  {{- if $v.storage.cache.pvcName }}
  - name: compile-cache
    persistentVolumeClaim:
      claimName: {{ $v.storage.cache.pvcName }}
  {{- end }}
{{- end }}
{{- end -}}

{{/* llmisvc.scheduler, with the pool of one port per data-parallel rank
     when llmisvc.dataParallelExternalLB.ranks is set (and the scheduler has
     no pool of its own), and flow control merged in. */}}
{{- define "md.scheduler" -}}
{{- $l := .Values.llmisvc -}}
{{- $sched := deepCopy ($l.scheduler | default dict) -}}
{{- $dp := $l.dataParallelExternalLB | default dict -}}
{{- $ranks := int ($dp.ranks | default 0) -}}
{{- $name := include "md.llmisvcName" . -}}
{{- if and (gt $ranks 1) (not (hasKey $sched "pool")) -}}
{{- $ports := list -}}
{{- range $i := until $ranks }}{{ $ports = append $ports (dict "number" (add 8000 $i)) }}{{ end -}}
{{- $_ := set $sched "pool" (dict "spec" (dict
      "appProtocol" "http"
      "endpointPickerRef" (dict "failureMode" "FailOpen" "group" "" "kind" "Service" "name" (printf "%s-epp-service" $name) "port" (dict "number" 9002))
      "selector" (dict "matchLabels" (dict "app.kubernetes.io/name" $name "app.kubernetes.io/part-of" "llminferenceservice" "kserve.io/component" "workload"))
      "targetPorts" $ports)) -}}
{{- end -}}
{{- if ($l.flowControl | default dict).enabled -}}
{{- $sched = include "md.schedulerWithFlowControl" (dict "Values" (dict "llmisvc" (merge (dict "scheduler" $sched) $l))) | fromYaml -}}
{{- end -}}
{{- toYaml $sched -}}
{{- end -}}
