# HƯỚNG DẪN TRIỂN KHAI MONITORING – NHÓM 10

- **Minikube:** Tạo môi trường Kubernetes trên máy cá nhân.
- **Prometheus:** Thu thập các chỉ số hoạt động của hệ thống.
- **Grafana:** Hiển thị các chỉ số dưới dạng biểu đồ.
- **Metrics Server:** Cung cấp dữ liệu CPU và RAM phục vụ HPA.
- **ServiceMonitor:** Cấu hình Prometheus thu thập chỉ số từ API Service và Catalogue Service.

## 2. Yêu cầu môi trường

Mỗi thành viên cần cài đặt:

- Docker Desktop
- Minikube
- kubectl
- Helm

Khởi động Minikube:

```bash
minikube start --driver=docker --memory=2048mb --cpus=2
```

Kiểm tra:

```bash
minikube status
kubectl get nodes
```

Kết quả mong đợi: Node `minikube` ở trạng thái `Ready`.

Lưu ý: 2 GB RAM là cấu hình khởi đầu theo yêu cầu nhóm. Khi chạy đồng thời các thành phần Monitoring và Microservices, có thể cần tăng tài nguyên tùy cấu hình máy.

## 3. Cài đặt Metrics Server

Metrics Server thu thập dữ liệu CPU và RAM của các Node, Pod. Đây là thành phần cần thiết để HPA tự động điều chỉnh số lượng Pod theo CPU.

Cài đặt:

```bash
minikube addons enable metrics-server
```

Kiểm tra:

```bash
kubectl top nodes
kubectl top pods -A
```

Nếu các lệnh hiển thị CPU và RAM, Metrics Server đã cung cấp dữ liệu thành công.

## 4. Cài đặt Prometheus và Grafana

Sử dụng Helm để triển khai bộ công cụ `kube-prometheus-stack`.

Thông tin cấu hình:

- Helm release: `prometheus`
- Namespace: `monitoring`
- Helm chart: `kube-prometheus-stack`
- Phiên bản chart đã sử dụng: `92.17.0`

Thêm Helm repository:

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update
```

Cài đặt:

```bash
helm upgrade --install prometheus prometheus-community/kube-prometheus-stack --version 92.17.0 --namespace monitoring --create-namespace
```

Hệ thống hiện tại được cài bằng các giá trị mặc định của Helm chart, không có file `values.yaml` tùy chỉnh.

Kiểm tra:

```bash
helm list -n monitoring
kubectl get pods -n monitoring
```

Các Pod Prometheus, Grafana và Prometheus Operator cần hoạt động bình thường.

## 5. Cấu hình ServiceMonitor

ServiceMonitor giúp Prometheus tự động tìm và thu thập dữ liệu từ các Service của ứng dụng.

File cấu hình:

`monitoring/servicemonitor.yaml`

Triển khai:

```bash
kubectl apply -f monitoring/servicemonitor.yaml
```

Kiểm tra:

```bash
kubectl get servicemonitor -n monitoring
```

Kết quả mong đợi xuất hiện:

`group10-services`

Cấu hình này giám sát hai ứng dụng:

| Ứng dụng | Cổng | Đường dẫn Metrics |
|---|---|---|
| API Service | 8000 | `/metrics` |
| Catalogue Service | 8001 | `/metrics` |

Yêu cầu: Hai Kubernetes Service phải có nhãn `app` tương ứng (`api-service` và `catalogue-service`), đồng thời có Service port tên `http`.

ServiceMonitor sử dụng nhãn `release: prometheus` để được Prometheus nhận diện.

**Lưu ý:** ServiceMonitor được tạo thành công không đồng nghĩa với việc hai ứng dụng đã được giám sát. Các ứng dụng phải được triển khai và hoạt động trước.

## 6. Truy cập Prometheus

Mở terminal và chạy:

```bash
kubectl -n monitoring port-forward svc/prometheus-kube-prometheus-prometheus 9090:9090
```

Truy cập:

http://localhost:9090

Vào **Status → Targets** để xem trạng thái các thành phần.

- `UP`: Prometheus thu thập được metrics.
- `DOWN`: Prometheus không thu thập được metrics từ target.

Khi tích hợp hoàn tất, cần kiểm tra target của API Service và Catalogue Service đều ở trạng thái `UP`.

## 7. Truy cập Grafana

Mở terminal khác và chạy:

```bash
kubectl -n monitoring port-forward svc/prometheus-grafana 3000:80
```

Truy cập:

http://localhost:3000

Tên đăng nhập mặc định: `admin`.

Mật khẩu được lưu trong Kubernetes Secret của Grafana. Không đưa mật khẩu vào GitHub.

Sau khi đăng nhập, kiểm tra nguồn dữ liệu Prometheus trong mục **Connections → Data sources**.

## 8. Các chỉ số cần giám sát

### 8.1. Chỉ số HTTP

Theo API Contract v1.0, các chỉ số gồm:

| Metrics | Ý nghĩa |
|---|---|
| `http_requests_total` | Tổng số HTTP request |
| `http_request_duration_seconds` | Thời gian xử lý HTTP request |
| `http_request_errors_total` | Tổng số request lỗi HTTP 4xx/5xx |

Các nhãn sử dụng: `method`, `route`, `status_code`.

### 8.2. Chỉ số Kubernetes

Grafana Dashboard cần hiển thị:

- CPU sử dụng.
- RAM sử dụng.
- Số lượng Pod đang chạy.
- Tốc độ xử lý request (RPS).
- Độ trễ xử lý request.
- Tỷ lệ request lỗi.

## 9. Yêu cầu tích hợp với các thành viên

**Thành viên 1 – API Service**

- Cung cấp Kubernetes Deployment và Service cho API.
- API Service chạy cổng 8000.
- Cung cấp endpoint `/metrics`.
- Cấu hình CPU requests để phục vụ HPA.

**Thành viên 2 – Catalogue Service**

- Triển khai Catalogue Service cổng 8001.
- Cung cấp endpoint `/metrics`.
- Bảo đảm Kubernetes Service có nhãn và tên cổng phù hợp với ServiceMonitor.

**Thành viên 3 – PostgreSQL và Load Testing**

- Triển khai PostgreSQL.
- Bảo đảm Catalogue kết nối được cơ sở dữ liệu.
- Phối hợp thực hiện kiểm thử tải bằng k6.

**Thành viên 4 – Ingress, Monitoring và HPA**

- Cấu hình Ingress và Rate Limiting.
- Triển khai Prometheus, Grafana và Metrics Server.
- Cấu hình ServiceMonitor.
- Xây dựng Grafana Dashboard.
- Kiểm thử giám sát và autoscaling khi hệ thống được tích hợp.

## 10. Kết quả đã thực hiện

Đã kiểm tra thành công trên Minikube cá nhân:

- Kubernetes Node ở trạng thái `Ready`.
- NGINX Ingress Controller hoạt động.
- Metrics Server cung cấp dữ liệu CPU và RAM.
- Prometheus hoạt động, có thể truy cập Targets.
- Grafana hoạt động và truy cập được trang đăng nhập.
- ServiceMonitor `group10-services` đã được tạo.
- File Ingress đã vượt qua bước kiểm tra dry-run.

Các nội dung còn phải thực hiện:

- Kiểm thử API Service và Catalogue Service với Prometheus.
- Hoàn thiện Grafana Dashboard.
- Kiểm thử định tuyến Ingress và Rate Limiting.
- Kiểm thử HPA tự động tăng, giảm Pod.
- Lưu kết quả kiểm thử và hình ảnh minh chứng.

**Lưu ý:** Các kết quả trên chỉ xác nhận môi trường Kubernetes trên máy Thành viên 4. Chưa phải kết quả kiểm thử end-to-end của toàn bộ hệ thống nhóm.