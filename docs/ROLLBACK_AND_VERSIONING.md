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
