// W4 - Tải để kiểm tra CPU HPA của catalogue-service (k6, chạy TRONG cụm bằng k6-job.yaml).
//
// Hình dạng tải: warm-up nhẹ -> tăng dần -> giữ đỉnh -> giảm về 0.
// Sau khi tải kết thúc, theo dõi tiếp bằng record_hpa.sh để thấy HPA giảm Pod (mặc định chờ ~5 phút).
//
// Cấu hình bằng biến môi trường (đặt trong k6-job.yaml):
//   BASE_URL   http://api-service:8000        (qua API, đúng timeline W4)
//              http://catalogue-service:8001  (gọi thẳng catalogue để tách riêng, nếu api-service nghẽn trước)
//   QUERY      chuỗi query thêm vào /products, mặc định rỗng.
//              Chỉ có tác dụng khi gọi THẲNG catalogue, ví dụ "?limit=500".
//              api-service gọi catalogue không kèm tham số nên bỏ qua query này.
//   PEAK_VUS   số người dùng ảo ở đỉnh (mặc định 30)
//   WARMUP     thời gian warm-up (mặc định 1m)
//   RAMP       thời gian tăng dần (mặc định 2m)
//   HOLD       thời gian giữ đỉnh (mặc định 5m)
//   THINK_SECONDS  thời gian nghỉ giữa 2 request của mỗi user (mặc định 0 = bắn liên tục)

import http from 'k6/http';
import { check, sleep } from 'k6';

const BASE_URL = __ENV.BASE_URL || 'http://api-service:8000';
const QUERY = __ENV.QUERY || '';
const PEAK_VUS = parseInt(__ENV.PEAK_VUS || '30', 10);
const WARMUP = __ENV.WARMUP || '1m';
const RAMP = __ENV.RAMP || '2m';
const HOLD = __ENV.HOLD || '5m';
const THINK = parseFloat(__ENV.THINK_SECONDS || '0');

export const options = {
  stages: [
    { duration: WARMUP, target: Math.max(1, Math.round(PEAK_VUS / 10)) },
    { duration: RAMP, target: PEAK_VUS },
    { duration: HOLD, target: PEAK_VUS },
    { duration: '30s', target: 0 },
  ],
  // Ngưỡng chỉ để báo "service có bị gián đoạn không" ở cuối log, không dừng bài test.
  thresholds: {
    http_req_failed: ['rate<0.01'],
    http_req_duration: ['p(95)<1000'],
  },
  summaryTrendStats: ['avg', 'min', 'med', 'p(90)', 'p(95)', 'p(99)', 'max'],
};

export default function () {
  const res = http.get(`${BASE_URL}/products${QUERY}`, {
    tags: { name: 'GET /products' },
  });
  check(res, { 'status 200': (r) => r.status === 200 });
  if (THINK > 0) {
    sleep(THINK);
  }
}

export function setup() {
  console.log(`BASE_URL=${BASE_URL} QUERY="${QUERY}" PEAK_VUS=${PEAK_VUS} WARMUP=${WARMUP} RAMP=${RAMP} HOLD=${HOLD}`);
  console.log(`Bắt đầu lúc ${new Date().toISOString()} (UTC). Ghi lại mốc này để đối chiếu với CSV.`);
}

export function teardown() {
  console.log(`Kết thúc lúc ${new Date().toISOString()} (UTC).`);
}
