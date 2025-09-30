kubectl -n airbyte-abctl scale statefulset airbyte-db --replicas=0
kubectl -n airbyte-abctl wait --for=delete pod/airbyte-db-0 --timeout=120s
cat <<'YAML' | kubectl -n airbyte-abctl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: pgfix
spec:
  restartPolicy: Never
  securityContext:
    fsGroup: 999
  containers:
  - name: fixer
    image: postgres:17-alpine
    env:
      - name: PGDATA
        value: /var/lib/postgresql/data/pgdata
    command: ["/bin/sh","-lc"]
    args:
      - |
        echo "PGDATA=$PGDATA"
        ls -lah "$PGDATA" || true
        # run pg_resetwal AS THE postgres USER
        su -s /bin/sh postgres -c "pg_resetwal -f \"$PGDATA\""
        echo "pg_resetwal done"
        rm -f "$PGDATA"/postmaster.pid
        sleep 2
        echo "Done. Sleeping so you can inspect logs..." && sleep 30
    volumeMounts:
      - name: db
        mountPath: /var/lib/postgresql/data
  volumes:
    - name: db
      persistentVolumeClaim:
        claimName: airbyte-volume-db-airbyte-db-0
YAML

# check it did the reset
kubectl -n airbyte-abctl logs pgfix
kubectl -n airbyte-abctl delete pod pgfix
kubectl -n airbyte-abctl scale statefulset airbyte-db --replicas=1
kubectl -n airbyte-abctl rollout status statefulset/airbyte-db --timeout=180s
kubectl -n airbyte-abctl logs pod/airbyte-db-0 --tail=120
kubectl -n airbyte-abctl rollout restart deploy/airbyte-abctl-server
kubectl -n airbyte-abctl rollout status deploy/airbyte-abctl-server --timeout=180s
kubectl -n airbyte-abctl rollout restart deploy/airbyte-abctl-server
kubectl -n airbyte-abctl rollout restart deploy/airbyte-abctl-worker
kubectl -n airbyte-abctl rollout restart deploy/airbyte-abctl-cron
kubectl -n airbyte-abctl rollout restart deploy/airbyte-abctl-temporal
kubectl -n airbyte-abctl get pods -w
curl -sS http://localhost:8001/api/v1/health