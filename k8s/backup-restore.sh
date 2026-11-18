set -euo pipefail

export MSYS_NO_PATHCONV=1

NS="${NAMESPACE:-default}"
POD="${POD:-postgres-0}"
DB="${DB_NAME:-catalogue_db}"
DBUSER="${DB_USER:-postgres}"
FILE="${2:-k8s/backup.sql}"

psql_in_pod() {
  kubectl exec -n "$NS" "$POD" -- psql -U "$DBUSER" -d "$DB" -v ON_ERROR_STOP=1 "$@"
}

count_products() {
  psql_in_pod -tAc "SELECT count(*) FROM products;"
}

case "${1:-}" in
  backup)
    echo ">> Backup $DB từ $NS/$POD vào $FILE"
    kubectl exec -n "$NS" "$POD" -- pg_dump -U "$DBUSER" -d "$DB" \
      --clean --if-exists --no-owner -f /tmp/backup.sql
    kubectl cp "$NS/$POD:/tmp/backup.sql" "$FILE"
    kubectl exec -n "$NS" "$POD" -- rm -f /tmp/backup.sql
    echo ">> Xong. Số sản phẩm lúc backup: $(count_products)"
    ;;

  restore)
    [ -f "$FILE" ] || { echo "Không tìm thấy file $FILE" >&2; exit 1; }
    echo ">> Restore $FILE vào $NS/$POD ($DB)"
    kubectl cp "$FILE" "$NS/$POD:/tmp/restore.sql"
    psql_in_pod -q -f /tmp/restore.sql
    kubectl exec -n "$NS" "$POD" -- rm -f /tmp/restore.sql
    echo ">> Xong. Số sản phẩm sau restore: $(count_products)"
    ;;

  verify)
    MARK="persistence-test-$(date +%s)"
    echo ">> 1. Ghi bản ghi đánh dấu: $MARK"
    psql_in_pod -qc "INSERT INTO products (name, price, stock) VALUES ('$MARK', 1, 1);"
    BEFORE="$(count_products)"
    echo ">> 2. Xóa Pod $POD (StatefulSet sẽ tạo lại Pod và gắn lại đúng PVC)"
    kubectl delete pod -n "$NS" "$POD" --wait=true
    for _ in $(seq 1 30); do
      kubectl get pod -n "$NS" "$POD" >/dev/null 2>&1 && break
      sleep 2
    done
    kubectl wait -n "$NS" --for=condition=Ready "pod/$POD" --timeout=180s
    AFTER="$(count_products)"
    FOUND="$(psql_in_pod -tAc "SELECT count(*) FROM products WHERE name = '$MARK';")"
    echo ">> Số sản phẩm trước: $BEFORE | sau: $AFTER | bản ghi đánh dấu còn: $FOUND"
    psql_in_pod -qc "DELETE FROM products WHERE name = '$MARK';"
    if [ "$FOUND" = "1" ] && [ "$BEFORE" = "$AFTER" ]; then
      echo "PASS: dữ liệu được giữ nguyên sau khi Pod bị tạo lại."
    else
      echo "FAIL: dữ liệu bị mất hoặc thay đổi sau khi Pod bị tạo lại." >&2
      exit 1
    fi
    ;;

  *)
    echo "Cách dùng: bash $0 {backup|restore|verify} [file]" >&2
    exit 1
    ;;
esac
