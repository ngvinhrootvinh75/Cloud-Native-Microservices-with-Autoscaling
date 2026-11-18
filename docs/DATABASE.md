# Database / Data Layer 

## 1. Lựa chọn

- PostgreSQL 15 (`postgres:15-alpine`), 1 database `catalogue_db`, chạy bằng StatefulSet 1 replica.
- Dữ liệu lưu trên PVC 1Gi (`ReadWriteOnce`), nên Pod bị xóa hoặc tạo lại vẫn giữ dữ liệu.
- DB **không** autoscale. Chỉ API và Catalogue (stateless) được gắn HPA.

## 2. Schema

Bảng `products` (nguồn sự thật: `k8s/init.sql`):

| Cột | Kiểu | Ràng buộc | Ghi chú |
|---|---|---|---|
| `id` | `SERIAL` | `PRIMARY KEY` | Tự tăng |
| `name` | `VARCHAR(255)` | `NOT NULL` | Tên sản phẩm |
| `description` | `TEXT` | cho phép `NULL` | Mô tả |
| `price` | `NUMERIC(10,2)` | `NOT NULL` | Giá. Catalogue trả về dạng số thực |
| `stock` | `INT` | `NOT NULL DEFAULT 0` | Tồn kho |
| `created_at` | `TIMESTAMP` | `DEFAULT CURRENT_TIMESTAMP` | Không trả ra API |

`init.sql` nạp 4 sản phẩm mẫu. Muốn có nhiều dữ liệu hơn cho load test: dùng `catalogue-service/scripts/seed.py` (xem README của catalogue).

> `init.sql` chỉ chạy khi volume còn trống (lần khởi tạo đầu tiên). Đổi `init.sql` thì phải xóa PVC hoặc tự chạy lệnh SQL tương ứng.

## 3. Kết nối

| Biến | Giá trị | Nguồn |
|---|---|---|
| `DB_HOST` | `postgres-service` | Service ClusterIP trong `database-statefulset.yaml` |
| `DB_PORT` | `5432` | |
| `DB_NAME` | `catalogue_db` | Secret `postgres-secret`, khóa `POSTGRES_DB` |
| `DB_USER` | `postgres` | Secret `postgres-secret`, khóa `POSTGRES_USER` |
| `DB_PASSWORD` | (trong Secret) | Secret `postgres-secret`, khóa `POSTGRES_PASSWORD` |

Connection string: `postgresql://<user>:<password>@postgres-service:5432/catalogue_db`

Giới hạn kết nối: PostgreSQL mặc định `max_connections = 100`. Catalogue mở tối đa `DB_POOL_MAX = 8` kết nối/Pod, nên với HPA `maxReplicas = 10` là tối đa 80 kết nối. Tăng `maxReplicas` thì phải giảm `DB_POOL_MAX`.

## 4. Các file

| File | Nội dung |
|---|---|
| `k8s/init.sql` | Schema + dữ liệu mẫu (dùng cho cả docker-compose) |
| `k8s/postgres-init-configmap.yaml` | ConfigMap sinh từ `init.sql`, không sửa tay |
| `k8s/postgres-secret.yaml` | Secret thông tin đăng nhập |
| `k8s/database-statefulset.yaml` | Headless Service, Service ClusterIP, StatefulSet + PVC |
| `k8s/backup-restore.sh` | Backup, restore, kiểm tra persistence |
| `k8s/backup.sql` | Bản backup mẫu (UTF-8) |

## 5. Triển khai và kiểm tra

```bash
kubectl apply -f k8s/postgres-secret.yaml
kubectl apply -f k8s/postgres-init-configmap.yaml
kubectl apply -f k8s/database-statefulset.yaml
kubectl wait --for=condition=Ready pod/postgres-0 --timeout=180s

kubectl exec postgres-0 -- psql -U postgres -d catalogue_db -c "SELECT id, name, price, stock FROM products;"
kubectl get pvc
```

Kiểm tra persistence, backup và restore (chạy bằng Git Bash):

```bash
bash k8s/backup-restore.sh verify    # in PASS nếu dữ liệu còn sau khi Pod bị tạo lại
bash k8s/backup-restore.sh backup    # ghi k8s/backup.sql
bash k8s/backup-restore.sh restore   # nạp lại từ k8s/backup.sql
```

