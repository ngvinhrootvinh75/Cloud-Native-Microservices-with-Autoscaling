# W4 – CPU HPA cho Catalogue (TV2)

Kiểm tra `catalogue-service-hpa` (min 2, max 10, CPU 70%) có tự tăng Pod khi có tải và giảm lại khi hết tải hay không, và dịch vụ có bị gián đoạn trong lúc scale hay không.

| File | Vai trò |
|---|---|
| `hpa-test.js` | Script tải k6: warm-up, tăng dần, giữ đỉnh, giảm về 0 |
| `k6-job.yaml` | Chạy k6 **trong cụm**, gọi thẳng `api-service:8000` (không qua Ingress) |
| `record_hpa.sh` | Ghi số replica, CPU, Pod Ready/Pending theo thời gian ra CSV |

Tiêu chí hoàn thành (timeline W4-TV2-01): Catalogue scale đúng min/max; service không gián đoạn. Đầu ra: `k8s/catalogue-hpa.yaml` và bảng kết quả (mục 7).

## 0. Điều kiện cần có trước khi chạy

```bash
kubectl get hpa                      # catalogue-service-hpa phải hiện cpu: x%/70%  (không phải <unknown>)
kubectl top pods                     # phải có số liệu CPU/RAM
kubectl apply -f k8s/hpa.yaml        # HPA của api-service (TV1). Nếu thiếu, api giữ 2 Pod và có thể nghẽn trước catalogue
```

**Nạp dữ liệu.** DB hiện chỉ có 4 dòng mẫu của TV3, mỗi request quá nhẹ để CPU chạm 70%. Nạp thêm 500 sản phẩm, **không dùng `--reset`** (để giữ 4 dòng mẫu cho TV3):

```bash
kubectl exec deploy/catalogue-service -- python scripts/seed.py --count 500
kubectl exec postgres-0 -- psql -U postgres -d catalogue_db -c "SELECT count(*) FROM products;"   # 504
```

**Kiểm tra cụm còn chỗ cho Pod mới.** Pod ở `Pending` với `Insufficient cpu` nghĩa là hết tài nguyên, và số Pod tối đa lúc đó là giới hạn của cụm, không phải của HPA:

```bash
kubectl describe node minikube      # xem mục "Allocated resources", ghi lại CPU Requests còn trống
```

## 1. Cửa sổ A: bật ghi số liệu (làm trước, chờ 1 đến 2 phút để có mốc lúc nhàn rỗi)

```bash
bash load-tests/w4-catalogue-hpa/record_hpa.sh w4-run1.csv 5
```
Giữ cửa sổ này chạy suốt bài test.

## 2. Cửa sổ B: bắn tải

```bash
kubectl create configmap k6-hpa-script --from-file=hpa-test.js=load-tests/w4-catalogue-hpa/hpa-test.js --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f load-tests/w4-catalogue-hpa/k6-job.yaml
kubectl logs -f job/k6-hpa-test
```
Tải kéo dài khoảng 8,5 phút (1m warm-up, 2m tăng dần, 5m giữ đỉnh, 30s giảm). Dòng đầu và cuối của log ghi giờ UTC bắt đầu và kết thúc, dùng để đối chiếu với cột `time_utc` trong CSV. Có thể mở thêm cửa sổ C chạy `kubectl get hpa -w` để xem trực tiếp.

Nếu CPU của catalogue không vượt 70% dù tải đã chạy vài phút:
- Tăng `PEAK_VUS` trong `k6-job.yaml` (ví dụ 60) rồi chạy lại (mục 6).
- Hoặc xem `api_cpu_pct` trong CSV: nếu api-service đã chạm 100% mà catalogue còn thấp, api đang là điểm nghẽn. Chạy lại bằng cách gọi thẳng catalogue (mục 5).

## 3. Sau khi k6 kết thúc: theo dõi giảm Pod

Để `record_hpa.sh` chạy tiếp cho đến khi `cat_current` về 2 (mặc định HPA chờ khoảng 5 phút ổn định mới giảm Pod, nên dành 6 đến 7 phút), rồi nhấn Ctrl+C.

## 4. Thu bằng chứng (làm ngay, vì Events của Kubernetes chỉ giữ khoảng 1 giờ)

```bash
kubectl logs job/k6-hpa-test > w4-k6-summary.txt
kubectl describe hpa catalogue-service-hpa > w4-hpa-events.txt   # có các dòng SuccessfulRescale kèm thời điểm
kubectl get pods -o wide > w4-pods.txt
```
Nộp kèm `w4-run1.csv`. Chụp thêm màn hình `kubectl get hpa -w` lúc đang scale nếu có.

## 5. Biến thể: gọi thẳng catalogue (tách riêng khỏi api-service)

```bash
kubectl delete job k6-hpa-test
sed -e 's#http://api-service:8000#http://catalogue-service:8001#' \
    -e '/name: QUERY/{n;s#value: ""#value: "?limit=500"#}' \
  load-tests/w4-catalogue-hpa/k6-job.yaml | kubectl apply -f -
```
Lệnh trên đổi mục tiêu sang catalogue và đặt `QUERY=?limit=500` để mỗi request trả nhiều dòng hơn, tốn CPU hơn (chạy trong Git Bash hoặc WSL). Chỉ gọi thẳng catalogue mới dùng được `QUERY`. Đi qua api-service thì `?limit=` bị bỏ qua, vì api-service gọi catalogue không kèm tham số và luôn nhận tối đa 100 dòng.

## 6. Chạy lại và dọn dẹp

```bash
kubectl delete job k6-hpa-test
kubectl delete configmap k6-hpa-script
```
Chờ HPA giảm về 2 Pod rồi mới chạy lần sau, để mỗi lần đo bắt đầu từ cùng một trạng thái. Đổi mức tải bằng cách sửa `PEAK_VUS`, `HOLD`... trong `env` của `k6-job.yaml`.

## 7. Cách đọc kết quả và bảng điền báo cáo

Từ CSV và `w4-hpa-events.txt`, điền bảng:

| Mốc | Thời điểm (UTC) | Replica | CPU % (HPA thấy) | Ghi chú |
|---|---|---|---|---|
| T0 bắt đầu tải | | | | |
| T1 CPU vượt 70% | | | | |
| T2 HPA đổi `desired` | | | | |
| T3 Pod mới Ready | | | | |
| T4 đạt số Pod đỉnh | | | | |
| T5 tải dừng | | | | |
| T6 bắt đầu giảm Pod | | | | |
| T7 về 2 Pod | | | | |

- Thời gian phản ứng = T2 − T1. Thời gian scale-up đến khi Pod sẵn sàng = T3 − T2. Độ trễ scale-down = T6 − T5.
- Mặc định HPA đánh giá mỗi 15 giây, Metrics Server trễ khoảng 15 đến 60 giây, và giảm Pod chờ cửa sổ ổn định 5 phút, nên các độ trễ tương ứng là bình thường.

Đạt tiêu chí khi:
- `cat_desired` tăng quá 2 sau khi `cat_cpu_pct` vượt 70, không vượt 10, và về lại 2 sau tải.
- `cat_pending` luôn bằng 0. Nếu khác 0, ghi rõ trong báo cáo số Pod tối đa thực tế đạt được và lý do (cụm hết tài nguyên).
- Không gián đoạn: cuối `w4-k6-summary.txt`, `http_req_failed` gần 0% và `checks` 100%, `cat_ready` không tụt dưới 2.

## 8. Lưu ý

- k6 chạy trong cùng cụm nên ăn CPU của cụm. Với Minikube 2 CPU, tăng `PEAK_VUS` quá cao làm k6 tranh CPU với chính hệ thống đang đo. Nên tăng dần và quan sát.
- Khi scale tới 10 Pod, DB có thể thành điểm nghẽn (theo `docs/DATABASE.md`, DB bão hòa CPU ở khoảng 50 kết nối đồng thời). Nếu latency tăng mà CPU catalogue không tăng, nghi ngờ DB.
- Báo TV1 lịch chạy, vì api-service cũng scale trong bài test này (các cột `api_*` trong CSV là số liệu của TV1).
