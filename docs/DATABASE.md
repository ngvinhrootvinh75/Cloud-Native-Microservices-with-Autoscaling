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


## 6. Baseline tài nguyên và giới hạn kết nối (tuần 4, TV3)

### 6.1. Môi trường đo

- Minikube, 2 GB RAM, 2 CPU (theo `monitoring/README.md`).
- PostgreSQL 15 (`postgres:15-alpine`), StatefulSet 1 replica, PVC 1Gi, giới hạn tài nguyên: 1 CPU, 512Mi RAM.
- Công cụ đo: `pgbench` chạy trong cụm, kết nối trực tiếp tới `postgres-service:5432`. Không đi qua API hay Catalogue, nên số liệu này phản ánh giới hạn của DB, không phải của toàn hệ thống.
- Database đo: `loadtest` (quy mô 10, khoảng 1 triệu dòng), tách khỏi `catalogue_db`.

### 6.2. Baseline khi nhàn rỗi

| Chỉ số | Giá trị |
|---|---|
| CPU `postgres-0` | 4–6m |
| RAM `postgres-0` | 25Mi |
| `max_connections` | 100 |
| `superuser_reserved_connections` | 3 |
| Kết nối đang dùng | 1 (phiên `psql` đo) |
| PVC | 1Gi, Bound, RWO |
| Dung lượng dữ liệu (`du`) | 91,5M (khoảng 9% PVC) |
| Restart / OOMKill | 0 |

Lưu ý: `df -h` trong môi trường minikube báo mount `/docker-entrypoint-initdb.d`, không phản ánh đúng PVC, nên dung lượng được lấy từ `du`.

### 6.3. Kết quả theo mức tải

| Mức | Client / thread | Thời gian | Giao dịch lỗi | Latency TB | TPS | CPU đỉnh | Kết nối active (log) |
|---|---|---|---|---|---|---|---|
| Đọc, thấp | 5 / 2 | 60 s | 0 | 0,652 ms | 7.671 | ~160m | 1–5 |
| Đọc, cao | 50 / 4 | 120 s | 0 | 7,678 ms | 6.512 | 1001m | 1–10 (+ ~45 idle) |
| Đọc, gần giới hạn | 95 / 2 | 30 s | 0 | 17,288 ms | 5.495 | — | — |
| Đọc, đúng giới hạn | 100 / 2 | 30 s | 0 | 17,717 ms | 5.644 | — | — |
| Đọc và ghi | 25 / 2 | 60 s | 0 | 26,261 ms | 952 | — | 22–26 |
| Vượt giới hạn | 101 / 2 | 30 s | Lỗi ở client 100 | — | — | — | — |

Ghi chú về CPU: Metrics Server cập nhật khoảng 15–60 giây một lần, nên các giá trị trên là xu hướng, không phải đỉnh chính xác.

### 6.4. Giới hạn kết nối

- Ở 100 client, PostgreSQL vẫn chấp nhận kết nối. Ở client thứ 101 báo: `FATAL: sorry, too many clients already`.
- Giới hạn thực tế là **100 kết nối**, vì pgbench và Catalogue đều đăng nhập bằng user `postgres` (superuser) và được dùng cả slot dành riêng.
- Với user không phải superuser, giới hạn còn 97 (100 − 3 slot dành riêng).

Công thức kiểm tra, dùng user `postgres` hiện tại:

`maxReplicas(Catalogue) × DB_POOL_MAX ≤ max_connections − dự phòng`

Hiện tại: `10 × 8 = 80 ≤ 100`, còn dư 20 kết nối cho `psql`, backup và truy vấn kiểm tra. Đạt.

### 6.5. Nhận xét

1. **DB bão hòa khi khoảng 50 client.** Từ mức này, tăng số client không làm tăng TPS. Latency tăng gần 12 lần từ 5 lên 50 client, CPU chạm giới hạn 1 core. Đây là nút thắt CPU, không phải giới hạn kết nối.
2. **Tải ghi chậm hơn tải đọc khoảng 7 lần** về TPS (952 so với 6.512 ở mức cao). Mỗi giao dịch ghi WAL và đồng bộ xuống đĩa. CPU ở tải ghi thấp hơn tải đọc, nên nghi ngờ nút thắt nằm ở I/O. Chưa đo I/O trực tiếp, cần kiểm chứng nếu có thời gian.
3. **RAM tăng từ 25Mi lên khoảng 375Mi** khi có tải, phần lớn là bộ nhớ đệm (shared buffers). Vẫn dưới 512Mi, nhưng cần theo dõi nếu tải tăng thêm.
4. **Không có restart hay OOMKill** trong suốt quá trình đo.

### 6.6. Đề xuất

- Giữ `DB_POOL_MAX = 8` và `maxReplicas = 10` (10 × 8 = 80, còn dư 20 kết nối dự phòng).
- Nếu muốn tăng `maxReplicas`, giảm `DB_POOL_MAX` sao cho `maxReplicas × DB_POOL_MAX ≤ 80`. Ví dụ: `maxReplicas = 12` thì `DB_POOL_MAX = 6`.
- Đề xuất TV2 tạo user ứng dụng riêng thay vì dùng `postgres`, để giới hạn kết nối và quyền rõ ràng hơn.
- Nếu muốn đưa số kết nối lên Grafana, cần exporter PostgreSQL riêng; nên bàn với TV4 trước.

### 6.7. Phạm vi chưa đo

- Tải end-to-end qua API và Catalogue, cùng hành vi HPA khi scale. Phụ thuộc TV2 hoàn thành triển khai Catalogue lên cụm.
- Đo I/O đĩa trực tiếp, để xác nhận nút thắt của tải ghi.
