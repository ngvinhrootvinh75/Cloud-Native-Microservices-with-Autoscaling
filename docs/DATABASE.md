# Database

## 1. Tổng quan

- Dùng PostgreSQL 15 (image `postgres:15-alpine`), database tên `catalogue_db`.
- Chạy bằng StatefulSet 1 replica, dữ liệu lưu trên PVC 1Gi (ReadWriteOnce), nên xóa Pod đi tạo lại thì dữ liệu vẫn còn.
- DB không gắn HPA. Chỉ API và Catalogue (stateless) mới autoscale.

## 2. Schema

Bảng `products`, định nghĩa trong `k8s/init.sql`:

| Cột | Kiểu | Ràng buộc | Ghi chú |
|---|---|---|---|
| `id` | `SERIAL` | `PRIMARY KEY` | Tự tăng |
| `name` | `VARCHAR(255)` | `NOT NULL` | Tên sản phẩm |
| `description` | `TEXT` | Có thể `NULL` | Mô tả |
| `price` | `NUMERIC(10,2)` | `NOT NULL` | Catalogue trả về dạng số thực |
| `stock` | `INT` | `NOT NULL DEFAULT 0` | Tồn kho |
| `created_at` | `TIMESTAMP` | `DEFAULT CURRENT_TIMESTAMP` | Không trả ra API |

`init.sql` có sẵn 4 sản phẩm mẫu. Cần nhiều dữ liệu hơn để test tải thì chạy `catalogue-service/scripts/seed.py` (xem README của catalogue).

Lưu ý: `init.sql` chỉ chạy lần đầu, khi volume còn trống. Nếu sửa file này thì phải xóa PVC hoặc tự chạy lệnh SQL bằng tay.

## 3. Kết nối

| Biến | Giá trị | Lấy từ đâu |
|---|---|---|
| `DB_HOST` | `postgres-service` | Service ClusterIP trong `database-statefulset.yaml` |
| `DB_PORT` | `5432` | |
| `DB_NAME` | `catalogue_db` | Secret `postgres-secret`, khóa `POSTGRES_DB` |
| `DB_USER` | `postgres` | Secret `postgres-secret`, khóa `POSTGRES_USER` |
| `DB_PASSWORD` | (trong Secret) | Secret `postgres-secret`, khóa `POSTGRES_PASSWORD` |

```
postgresql://<user>:<password>@postgres-service:5432/catalogue_db
```

PostgreSQL mặc định cho tối đa 100 kết nối. Mỗi Pod Catalogue mở tối đa 8 kết nối (`DB_POOL_MAX = 8`), HPA cho tối đa 10 Pod, vậy tối đa 80 kết nối, còn dư 20 cho `psql`, backup,... Nếu tăng `maxReplicas` thì phải giảm `DB_POOL_MAX` để `maxReplicas × DB_POOL_MAX ≤ 80` (ví dụ 12 Pod thì pool 6).

## 4. Các file

| File | Nội dung |
|---|---|
| `k8s/init.sql` | Schema + dữ liệu mẫu (docker-compose cũng dùng file này) |
| `k8s/postgres-init-configmap.yaml` | ConfigMap sinh từ `init.sql`, không sửa tay |
| `k8s/postgres-secret.yaml` | Thông tin đăng nhập |
| `k8s/database-statefulset.yaml` | Headless Service, Service ClusterIP, StatefulSet + PVC |
| `k8s/backup-restore.sh` | Backup, restore, kiểm tra persistence |
| `k8s/backup.sql` | File backup mẫu (UTF-8) |

## 5. Triển khai và kiểm tra

```bash
kubectl apply -f k8s/postgres-secret.yaml
kubectl apply -f k8s/postgres-init-configmap.yaml
kubectl apply -f k8s/database-statefulset.yaml
kubectl wait --for=condition=Ready pod/postgres-0 --timeout=180s

kubectl exec postgres-0 -- psql -U postgres -d catalogue_db -c "SELECT id, name, price, stock FROM products;"
kubectl get pvc
```

Backup, restore và kiểm tra persistence (chạy bằng Git Bash):

```bash
bash k8s/backup-restore.sh verify    # in PASS nếu tạo lại Pod mà dữ liệu vẫn còn
bash k8s/backup-restore.sh backup    # ghi ra k8s/backup.sql
bash k8s/backup-restore.sh restore   # nạp lại từ k8s/backup.sql
```

## 6. Đo tải

### 6.1. Môi trường đo

- Minikube 2 CPU, 2 GB RAM (theo `monitoring/README.md`). Pod `postgres-0` giới hạn 1 CPU, 512Mi RAM.
- Dùng `pgbench` chạy trong cụm, gọi thẳng vào `postgres-service:5432`, không qua API hay Catalogue. Vì vậy số liệu ở đây chỉ cho biết giới hạn của riêng DB, không phải của cả hệ thống.
- Đo trên một database riêng là `loadtest` (scale 10, khoảng 1 triệu dòng) để không đụng vào `catalogue_db`.

### 6.2. Baseline khi nhàn rỗi

| Chỉ số | Giá trị |
|---|---|
| CPU `postgres-0` | 4–6m |
| RAM `postgres-0` | 25Mi |
| `max_connections` | 100 |
| `superuser_reserved_connections` | 3 |
| Kết nối đang dùng | 1 (phiên `psql` dùng để đo) |
| PVC | 1Gi, Bound, RWO |
| Dung lượng dữ liệu (`du`) | 91,5M (khoảng 9% PVC) |
| Restart / OOMKill | 0 |

Dung lượng đo bằng `du` vì `df -h` trên minikube hiện mount `/docker-entrypoint-initdb.d`, không phải PVC.

### 6.3. Kết quả pgbench

| Kịch bản | Client / thread | Thời gian | Giao dịch lỗi | Latency TB | TPS | CPU đỉnh | Kết nối active |
|---|---|---|---|---|---|---|---|
| Đọc, thấp | 5 / 2 | 60 s | 0 | 0,652 ms | 7.671 | ~160m | 1–5 |
| Đọc, cao | 50 / 4 | 120 s | 0 | 7,678 ms | 6.512 | 1001m | 1–10 (+ ~45 idle) |
| Đọc, gần giới hạn | 95 / 2 | 30 s | 0 | 17,288 ms | 5.495 | – | – |
| Đọc, đúng giới hạn | 100 / 2 | 30 s | 0 | 17,717 ms | 5.644 | – | – |
| Đọc + ghi | 25 / 2 | 60 s | 0 | 26,261 ms | 952 | – | 22–26 |
| Vượt giới hạn | 101 / 2 | 30 s | Lỗi ở client 101 | – | – | – | – |

CPU lấy từ Metrics Server, cập nhật 15–60 giây một lần, nên chỉ xem là số gần đúng chứ không phải đỉnh chính xác.

Nhận xét:

- Tới khoảng 50 client là DB bão hòa: CPU chạm 1 core, TPS không tăng nữa mà còn giảm nhẹ, latency gấp khoảng 12 lần so với lúc 5 client. Tức là nghẽn ở CPU chứ chưa phải ở số kết nối.
- Đọc + ghi chỉ được 952 TPS, chậm hơn chỉ đọc khoảng 7 lần. CPU lúc ghi lại thấp hơn lúc đọc, nên nhóm đoán nghẽn nằm ở I/O đĩa (mỗi giao dịch phải ghi WAL xuống đĩa). Tuy nhiên nhóm chưa đo I/O nên chưa khẳng định được.
- Khi có tải, RAM lên khoảng 375Mi (chủ yếu là cache), vẫn dưới limit 512Mi.
- Trong suốt quá trình đo không có restart hay OOMKill.

### 6.4. Giới hạn kết nối

Client thứ 101 báo lỗi `FATAL: sorry, too many clients already`. Giới hạn là đúng 100 vì pgbench và Catalogue đều dùng user `postgres` (superuser), nên được dùng luôn 3 slot dự phòng. Nếu dùng user thường thì chỉ còn 97.

### 6.5. Kết quả kiểm chứng thực tế khi tải end-to-end (k6 + HPA)

Ngoài pgbench, chạy thêm k6 (30 VU, 8 phút 30 giây, gọi qua API Service) để xem DB chạy thực tế thế nào khi có HPA.

Số liệu hệ thống lúc tải đỉnh:

| Chỉ số | Nhàn rỗi (2 Pod) | Tải đỉnh | Giới hạn |
|---|---|---|---|
| Số Pod API | 2 | 10 | max 10 |
| CPU API (theo HPA) | 3% | 310%, giảm về 115% khi đủ 10 Pod | target 70% |
| Số Pod Catalogue | 2 | 5 | max 10 |
| CPU Catalogue (theo HPA) | 3% | 131%, giảm về 67% khi đủ 5 Pod | target 70% |
| CPU `postgres-0` | 5m | 64m | 1000m |
| RAM `postgres-0` | 37Mi | 84Mi | 512Mi |
| Kết nối DB (`pg_stat_activity`) | 1–2 | 34 | 100 (pool tối đa 80) |
| Giao dịch lỗi phía DB | 0 | 0 | 0 |
| Số sản phẩm trong DB | 504 | 504 | – |

Thống kê k6 (End-to-End qua API):

| Thông số | Giá trị |
|---|---|
| Thời gian chạy | 8m30s (510 s) |
| Người dùng ảo tối đa tối đa | 30 |
| Tổng request (`http_reqs`) | 24.881 |
| Throughput trung bình | 48,79 req/s |
| Tỷ lệ lỗi (`http_req_failed`) | 0,00% (24.881 / 24.881 mã 200) |
| Latency trung bình | 460,61 ms |
| Latency trung vị | 397,56 ms |
| Độ trễ phân vị 90 (`p90`) | 1.000 ms |
| Độ trễ phân vị 95 (`p95`) | 1.190 ms |
| Độ trễ tối đa (`max`) | 2.190 ms |
| Dữ liệu nhận về | 296 MB |

Nhận xét:

- 5 Pod Catalogue chỉ mở 34 kết nối, thấp hơn nhiều so với mức 80 tính ở mục 3, và không có lỗi `too many clients`.
- DB gần như không bị ảnh hưởng (64m CPU, 84Mi RAM). Chỗ nghẽn là `api-service`: CPU lên tới 310% và phải scale tới 10 Pod. Đủ 10 Pod rồi mà CPU vẫn còn 115%, cao hơn target 70%, nên nếu tải tăng nữa thì API sẽ là chỗ cần xử lý trước.
- Sau khi HPA scale lên rồi scale xuống, DB không bị gián đoạn, vẫn đủ 504 sản phẩm.
