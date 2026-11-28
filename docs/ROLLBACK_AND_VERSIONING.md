# Quy ước Versioning, Quản lý Cấu hình và Rollback Checklist 

Hướng 1: CI/CD Pipeline và Rolling Update Zero Downtime.

---

## 1. Quy ước Image Tagging & Versioning

Áp dụng cho pipeline CI (API Service) và (Catalogue Service) khi build Docker image:

### 1.1. Cấu trúc Tag
Sử dụng chuẩn **Semantic Versioning (SemVer)**: `vMAJOR.MINOR.PATCH`

- **`v1.0.0`**: Bản phát hành ổn định ban đầu .
- **`v1.0.1`**: Bản vá lỗi nhỏ (bug fix), không đổi cấu trúc API hay DB schema.
- **`v1.1.0`**: Thêm tính năng mới (endpoint mới, query mới) nhưng tương thích ngược.
- **`v2.0.0`**: Thay đổi lớn, phá vỡ tương thích (đổi cấu trúc bảng, đổi format response).

Đối với các bản build tự động từ GitHub Actions trên từng commit, nên gắn mã Git commit SHA ngắn:
`v1.0.0-<short_commit_sha>` (ví dụ: `v1.0.0-95997aa`).

### 1.2. Quy tắc bắt buộc
> **TUYỆT ĐỐI KHÔNG DÙNG TAG `:latest` TRONG KUBERNETES MANIFEST.**

Lý do kỹ thuật:
1. **Không kích hoạt được Rolling Update:** Kubernetes so sánh tên image trong Deployment. Nếu dùng `:latest`, tên image không đổi giữa các lần cập nhật nên Kubernetes không nhận diện được phiên bản mới để tự động thay thế Pod.
2. **Không thể Rollback:** Khi triển khai bản mới bị lỗi, lệnh `kubectl rollout undo` sẽ không có tác dụng vì cả bản cũ và bản mới đều mang tên `:latest`.
3. **Mất dấu vết (Audit trail):** Không thể xác định Pod đang chạy trên cụm tương ứng với commit nào trong mã nguồn.

---

## 2. Quản lý Cấu hình & Secret khi Cập nhật Ứng dụng

### 2.1. Phân tách Cấu hình
- **Cấu hình tĩnh / không nhạy cảm:** Đặt trong `ConfigMap` hoặc biến môi trường trực tiếp trong Deployment.
- **Thông tin đăng nhập & Bảo mật:** Bắt buộc lưu trữ trong Kubernetes Secret (`k8s/postgres-secret.yaml`), gồm `POSTGRES_DB`, `POSTGRES_USER`, `POSTGRES_PASSWORD`.

### 2.2. Nguyên tắc triển khai an toàn
1. Không commit mật khẩu dạng plain text lên GitHub.
2. Khi cập nhật ứng dụng, file Secret và ConfigMap phải được `kubectl apply` **trước** khi cập nhật Deployment của API hay Catalogue.
3. Trong Deployment, tham chiếu mật khẩu qua `secretKeyRef`:
   ```yaml
   env:
     - name: DB_PASSWORD
       valueFrom:
         secretKeyRef:
           name: postgres-secret
           key: POSTGRES_PASSWORD
   ```

---

## 3. Tính bền vững Dữ liệu (Persistence) khi Rolling Update

- **Kiến trúc phân tách:** Database PostgreSQL chạy độc lập dưới dạng `StatefulSet` 1 replica gắn với PVC 1Gi (`ReadWriteOnce`).
- Khi thực hiện Rolling Update ứng dụng (`catalogue-service` từ `v1` lên `v2`):
  1. Pod DB `postgres-0` **không bị khởi động lại**.
  2. Toàn bộ dữ liệu trong volume PVC được giữ nguyên vẹn.
  3. Để tránh rò rỉ kết nối trong DB, mỗi Pod Catalogue có cấu hình `terminationGracePeriodSeconds: 30`. Khi Pod cũ nhận tín hiệu dừng (`SIGTERM`), connection pool sẽ đóng các kết nối hiện thời trong 30 giây trước khi Pod bị xoá.

---

## 4. Rollback Checklist (Quy trình Xử lý Sự cố)

Khi quá trình triển khai phiên bản mới gặp sự cố trên cụm, làm theo checklist sau:

### Kịch bản 1: Ứng dụng mới gặp lỗi (Crash, lỗi code, lỗi cấu hình, không kéo được image)

- [ ] **Bước 1: Kiểm tra lịch sử các lần rollout của Deployment**
  ```bash
  kubectl rollout history deployment/catalogue-service
  ```
- [ ] **Bước 2: Xem chi tiết revision trước đó**
  ```bash
  kubectl rollout history deployment/catalogue-service --revision=1
  ```
- [ ] **Bước 3: Thực hiện lệnh Rollback về phiên bản ổn định gần nhất**
  ```bash
  kubectl rollout undo deployment/catalogue-service
  ```
  *(Hoặc quay về một revision cụ thể: `kubectl rollout undo deployment/catalogue-service --to-revision=1`)*
- [ ] **Bước 4: Theo dõi quá trình khôi phục hoàn tất**
  ```bash
  kubectl rollout status deployment/catalogue-service
  ```
- [ ] **Bước 5: Kiểm tra Pods đã quay về trạng thái 1/1 Running**
  ```bash
  kubectl get pods -l app=catalogue-service
  ```

---

### Kịch bản 2: Phiên bản mới làm sai lệch hoặc hỏng dữ liệu trong Database

Nếu mã nguồn mới thực hiện sai truy vấn hoặc ghi đè dữ liệu sai lệch:

- [ ] **Bước 1: Tạm thời cô lập ứng dụng (ngắt ghi xuống DB)**
  Scale ứng dụng về 0 bản sao để ngăn client tiếp tục ghi lỗi:
  ```bash
  kubectl scale deployment/catalogue-service --replicas=0
  ```
- [ ] **Bước 2: Phục hồi dữ liệu DB từ bản backup an toàn gần nhất**
  Sử dụng script khôi phục có sẵn:
  ```bash
  bash k8s/backup-restore.sh restore
  ```
  *(Lệnh sẽ nạp lại dữ liệu từ `k8s/backup.sql` vào `catalogue_db`).*
- [ ] **Bước 3: Xác minh lại số lượng bản ghi trong database**
  ```bash
  kubectl exec postgres-0 -- psql -U postgres -d catalogue_db -c "SELECT count(*) FROM products;"
  ```
  *(Đảm bảo số lượng sản phẩm quay lại đúng mốc 504).*
- [ ] **Bước 4: Rollback ứng dụng về bản mã nguồn an toàn**
  ```bash
  kubectl rollout undo deployment/catalogue-service
  ```
- [ ] **Bước 5: Mở lại bản sao ứng dụng để phục vụ người dùng**
  ```bash
  kubectl scale deployment/catalogue-service --replicas=2
  ```
  Kiểm tra kết nối: `kubectl exec postgres-0 -- psql -U postgres -d catalogue_db -c "SELECT count(*) FROM pg_stat_activity;"`
---

## 5. CD và Rolling Update cho API Service (TV4)

### 5.1. Cấu hình Rolling Update

Trong `k8s/api-deployment.yaml` (giống `catalogue-deployment.yaml`):

```yaml
strategy:
  type: RollingUpdate
  rollingUpdate:
    maxUnavailable: 0   # không tắt Pod cũ khi Pod mới chưa Ready
    maxSurge: 1         # được tạo thêm tối đa 1 Pod mới trong lúc cập nhật
```

Trình tự: tạo 1 Pod mới → chờ Pod mới Ready (readinessProbe `/ready`) → tắt 1 Pod cũ → lặp lại.
Số Pod Ready không bao giờ thấp hơn số replica hiện tại, kể cả khi HPA đã scale lên 10 Pod
(mặc định của Kubernetes là 25%, với 10 Pod sẽ cho phép tắt cùng lúc 2 Pod).

### 5.2. Deploy phiên bản mới bằng script CD

Script: `deploy/deploy.ps1`

```powershell
powershell -ExecutionPolicy Bypass -File deploy\deploy.ps1 -Tag v1.0.1
# Service khác:              -Service catalogue-service
# Image từ Docker Hub (CI):  -ImageName <dockerhub_user>/api-service
```

Script thực hiện:
1. Kiểm tra tag đúng quy ước mục 1 (`vX.Y.Z` hoặc `vX.Y.Z-<sha>`), từ chối `:latest`.
2. `kubectl set image` sang image mới.
3. Ghi `kubernetes.io/change-cause` để `kubectl rollout history` hiển thị phiên bản và thời điểm deploy.
4. Chờ `kubectl rollout status` (tối đa 180 giây).
5. Nếu rollout thất bại hoặc quá thời gian: **tự động `kubectl rollout undo`** về phiên bản trước.

### 5.3. Rollback Checklist cho API Service

Áp dụng Kịch bản 1 (mục 4) cho `api-service`:

- [ ] **Bước 1: Xem lịch sử phiên bản**
  ```bash
  kubectl rollout history deployment/api-service
  ```
- [ ] **Bước 2: Rollback về phiên bản trước**
  ```bash
  kubectl rollout undo deployment/api-service
  ```
  *(Hoặc về revision cụ thể: `kubectl rollout undo deployment/api-service --to-revision=<số>`)*
- [ ] **Bước 3: Theo dõi đến khi hoàn tất**
  ```bash
  kubectl rollout status deployment/api-service
  ```
- [ ] **Bước 4: Kiểm tra image và Pod**
  ```bash
  kubectl get deploy api-service -o jsonpath="{.spec.template.spec.containers[0].image}"
  kubectl get pods -l app=api-service
  ```

Ghi chú:
- Khi rollback, Kubernetes dùng lại ReplicaSet cũ (cùng `pod-template-hash` trong tên Pod) nên rollback nhanh.
  Revision cũ được đánh số mới (ví dụ revision 2 thành revision 4).
- `kubectl rollout undo` không cập nhật annotation `last-applied-configuration`. Nếu sau đó chạy
  `kubectl apply -f k8s/api-deployment.yaml`, image sẽ bị đưa về đúng tag ghi trong file manifest.
  Cần cập nhật tag trong manifest cho khớp phiên bản đang chạy.

### 5.4. Kiểm thử Rolling Update và Rollback khi có tải

**Môi trường:** Minikube 1 node (2 CPU, 2 GB RAM), api-service 2 replica, HPA CPU 70% (min 2, max 10).
Image build cục bộ bằng `minikube image build -t nt533-api-service:<tag> ./api-service`.

**Tải:** Job `load-tests/k6-rolling-job.yaml`, dùng lại script `load-tests/hpa-test.js` (TV2):
5 VU, nghỉ 0,2 giây giữa 2 request, gọi `GET http://api-service:8000/products` trong cụm (không qua Ingress).
Warm-up 30s, tăng tải 30s, giữ tải 4 phút; deploy/rollback chạy khoảng 75 giây sau khi tải ổn định.

**Kết quả (28/11/2026):**

| Lần | Thao tác | Thời gian rollout | Tổng request | Lỗi | p95 | Max |
|---|---|---|---|---|---|---|
| 1 | Deploy v1.0.0 → v1.0.1 | 13 s | 6.117 (18,5 req/s) | **0 (0%)** | 35,4 ms | 273 ms |
| 2 | Rollback v1.0.1 → v1.0.0 | 12 s | 6.273 (19,0 req/s) | **6 (0,09%)** | 22,7 ms | 37 ms |

- Mỗi Pod mới Ready sau khoảng 6 giây; Pod cũ chỉ bị tắt sau khi Pod mới Ready.
- Cả hai lần: Restarts = 0, Pending = 0, Pod DB `postgres-0` không bị ảnh hưởng.
- Minh chứng: `load-tests/results/w5/` (log k6 và lịch sử revision).

### 5.5. Phân tích lỗi khi Rollback và đề xuất

Log k6 lần 2:

```
16:38:15Z  connection refused  (2 request)
16:38:21Z  connection refused  (3 request)
16:38:51Z  i/o timeout         (1 request)
```

Hai mốc cách nhau 6 giây, trùng thời điểm tắt Pod cũ thứ nhất và thứ hai. Khi Pod bị tắt, Kubernetes đồng thời
gửi `SIGTERM` cho ứng dụng (uvicorn ngừng nhận kết nối ngay) và gỡ Pod khỏi endpoint của Service
(cần thêm vài giây để kube-proxy cập nhật). Trong khoảng chênh lệch đó, một số request vẫn được chuyển tới Pod đang tắt.
Lỗi mang tính ngẫu nhiên: lần 1 không gặp, lần 2 gặp.

**Đề xuất:** thêm `preStop` hook vào container của API và Catalogue để Pod chờ 5 giây trước khi nhận `SIGTERM`:

```yaml
lifecycle:
  preStop:
    exec:
      command: ["sleep", "5"]
```

Thời gian chờ này nằm trong `terminationGracePeriodSeconds` (mặc định 30 giây) nên không ảnh hưởng mục 3.
Sau khi TV1, TV2 thêm `preStop`, chạy lại 2 bài kiểm thử trên để so sánh trước/sau.