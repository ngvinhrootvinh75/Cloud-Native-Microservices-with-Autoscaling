#!/usr/bin/env bash
# Ghi số replica, CPU, Pod Ready/Pending của catalogue-service (và api-service) theo thời gian ra file CSV.
# Chạy trong một cửa sổ riêng, TRƯỚC khi bắn tải và dừng sau khi HPA đã giảm Pod về min (Ctrl+C).
#
#   bash load-tests/w4-catalogue-hpa/record_hpa.sh                 # ghi vào hpa-metrics.csv, 5 giây/lần
#   bash load-tests/w4-catalogue-hpa/record_hpa.sh w4-run1.csv 5
#
# Cột CSV:
#   time_utc, elapsed_s
#   cat_current / cat_desired   số replica hiện tại / HPA muốn có của catalogue
#   cat_cpu_pct                 CPU trung bình theo % request mà HPA đang thấy (đích 70)
#   cat_cpu_total_m             tổng CPU (milicore) của các Pod catalogue theo kubectl top
#   cat_ready / cat_pending     số Pod Ready / Pending (Pending = cụm hết tài nguyên)
#   api_*                       tương tự cho api-service (trống nếu chưa có HPA của api)
#
# Lưu ý: kubectl top / Metrics Server cập nhật khoảng 15-60 giây một lần, nên CPU là xu hướng,
# không phải giá trị tức thời.

OUT="${1:-hpa-metrics.csv}"
INTERVAL="${2:-5}"

CAT_APP="${CAT_APP:-catalogue-service}"
CAT_HPA="${CAT_HPA:-catalogue-service-hpa}"
API_APP="${API_APP:-api-service}"
API_HPA="${API_HPA:-api-service-hpa}"

START=$(date +%s)

# hpa_fields <tên-hpa> -> in "current desired cpu_pct" (trống nếu HPA không tồn tại)
hpa_fields() {
  kubectl get hpa "$1" -o jsonpath='{.status.currentReplicas}{" "}{.status.desiredReplicas}{" "}{.status.currentMetrics[0].resource.current.averageUtilization}' 2>/dev/null
}

# cpu_total_m <app> -> tổng CPU milicore của các Pod có label app=<app>
cpu_total_m() {
  kubectl top pods -l "app=$1" --no-headers 2>/dev/null | awk '{ v = $2; gsub("m", "", v); s += v } END { print s + 0 }'
}

# ready_count <deployment> -> số replica Ready (0 nếu chưa có)
ready_count() {
  local n
  n=$(kubectl get deploy "$1" -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
  echo "${n:-0}"
}

# pending_count <app> -> số Pod đang Pending
pending_count() {
  kubectl get pods -l "app=$1" --field-selector=status.phase=Pending --no-headers 2>/dev/null | wc -l | tr -d ' '
}

echo "time_utc,elapsed_s,cat_current,cat_desired,cat_cpu_pct,cat_cpu_total_m,cat_ready,cat_pending,api_current,api_desired,api_cpu_pct,api_cpu_total_m,api_ready,api_pending" > "$OUT"
echo "Ghi vào $OUT mỗi ${INTERVAL}s. Nhấn Ctrl+C để dừng."
printf '%-9s %-7s | %-22s | %-22s\n' "elapsed" "" "catalogue cur/des cpu% Ready Pend" "api cur/des cpu% Ready Pend"

while true; do
  now=$(date -u +%H:%M:%S)
  elapsed=$(( $(date +%s) - START ))

  read -r c_cur c_des c_pct <<< "$(hpa_fields "$CAT_HPA")"
  c_m=$(cpu_total_m "$CAT_APP")
  c_rdy=$(ready_count "$CAT_APP")
  c_pen=$(pending_count "$CAT_APP")

  read -r a_cur a_des a_pct <<< "$(hpa_fields "$API_HPA")"
  a_m=$(cpu_total_m "$API_APP")
  a_rdy=$(ready_count "$API_APP")
  a_pen=$(pending_count "$API_APP")

  echo "$now,$elapsed,$c_cur,$c_des,$c_pct,$c_m,$c_rdy,$c_pen,$a_cur,$a_des,$a_pct,$a_m,$a_rdy,$a_pen" >> "$OUT"
  printf '%-9s %-7s | %-3s/%-3s %-5s %-5s %-5s | %-3s/%-3s %-5s %-5s %-5s\n' \
    "${elapsed}s" "$now" "${c_cur:--}" "${c_des:--}" "${c_pct:--}" "$c_rdy" "$c_pen" \
    "${a_cur:--}" "${a_des:--}" "${a_pct:--}" "$a_rdy" "$a_pen"

  sleep "$INTERVAL"
done
