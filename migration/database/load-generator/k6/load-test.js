import http from 'k6/http';
import { check, sleep, group } from 'k6';
import { Counter, Trend, Rate, Gauge } from 'k6/metrics';
import { config } from './config.js';

// ==========================================
// Custom Metrics
// ==========================================
const errorCount = new Counter('migration_errors');
const successCount = new Counter('migration_success');
const writeLatency = new Trend('write_latency', true);
const readLatency = new Trend('read_latency', true);
const errorRate = new Rate('error_rate');
const activeVUs = new Gauge('active_vus');

// 전환 감지용 (연속 에러 추적)
const consecutiveErrors = new Counter('consecutive_errors');

// ==========================================
// Test Options
// ==========================================
export const options = {
  scenarios: {
    // Phase 1: Baseline (기준선 측정)
    baseline: {
      executor: 'constant-arrival-rate',
      rate: config.qps.baseline,
      timeUnit: '1s',
      duration: config.duration.baseline,
      preAllocatedVUs: 500,
      maxVUs: 1000,
      startTime: '0s',
      tags: { phase: 'baseline' },
    },

    // Phase 2: Replication (복제 중 테스트 + 스파이크)
    replication: {
      executor: 'ramping-arrival-rate',
      startRate: config.qps.baseline,
      timeUnit: '1s',
      preAllocatedVUs: 500,
      maxVUs: 1500,
      startTime: config.duration.baseline,
      stages: [
        { duration: '3m', target: config.qps.baseline },  // 유지
        { duration: '1m', target: config.qps.spike },     // 스파이크 상승
        { duration: '2m', target: config.qps.spike },     // 스파이크 유지
        { duration: '1m', target: config.qps.baseline },  // 하락
        { duration: '3m', target: config.qps.baseline },  // 유지
      ],
      tags: { phase: 'replication' },
    },

    // Phase 3: Cutover (전환 - 수동 트리거 권장)
    // 실제 전환 시에는 별도 스크립트로 실행
    cutover: {
      executor: 'constant-arrival-rate',
      rate: config.qps.baseline,
      timeUnit: '1s',
      duration: '5m',
      preAllocatedVUs: 500,
      maxVUs: 1000,
      startTime: '20m', // baseline + replication 후
      tags: { phase: 'cutover' },
    },

    // Phase 4: Post-Cutover (전환 후 안정성)
    post_cutover: {
      executor: 'constant-arrival-rate',
      rate: config.qps.baseline,
      timeUnit: '1s',
      duration: config.duration.postCutover,
      preAllocatedVUs: 500,
      maxVUs: 1000,
      startTime: '25m',
      tags: { phase: 'post_cutover' },
    },
  },

  thresholds: {
    'error_rate': [`rate<${config.thresholds.maxErrorRate}`],
    'write_latency': [`p(95)<${config.thresholds.p95LatencyMs}`],
    'read_latency': [`p(95)<${config.thresholds.p95LatencyMs}`],
    'http_req_duration': [`p(99)<${config.thresholds.p99LatencyMs}`],
  },
};

// ==========================================
// Setup
// ==========================================
export function setup() {
  console.log(`Target URL: ${config.baseUrl}`);
  console.log(`Test Group ID: ${config.testGroupId}`);
  console.log(`Baseline QPS: ${config.qps.baseline}`);

  // Health check
  const healthRes = http.get(`${config.baseUrl}/actuator/health`, {
    timeout: '5s',
  });

  if (healthRes.status !== 200) {
    console.warn(`Health check failed: ${healthRes.status}`);
  }

  return {
    startTime: Date.now(),
    groupId: config.testGroupId,
  };
}

// ==========================================
// Main Test Function
// ==========================================
export default function (data) {
  const seq = __ITER;
  const timestamp = Date.now();
  const headers = {
    'Content-Type': 'application/json',
  };

  // 인증 토큰이 있으면 추가
  if (config.authToken) {
    headers['Authorization'] = `Bearer ${config.authToken}`;
  }

  activeVUs.add(__VU);

  // ==========================================
  // Write Operation (POST 생성)
  // ==========================================
  group('write_operations', function () {
    const writePayload = JSON.stringify({
      title: `load-test-${seq}-${timestamp}`,
      content: `migration-validation-${seq}-${__VU}`,
      rentalFee: Math.floor(1000 + Math.random() * 9000),
      feeUnit: 'DAY',
      imageUrls: [],
    });

    const writeRes = http.post(
      `${config.baseUrl}/groups/${data.groupId}/posts`,
      writePayload,
      {
        headers: headers,
        tags: { type: 'write', operation: 'create_post' },
        timeout: '10s',
      }
    );

    writeLatency.add(writeRes.timings.duration);

    const writeOk = check(writeRes, {
      'write status 2xx': (r) => r.status >= 200 && r.status < 300,
      'write has body': (r) => r.body && r.body.length > 0,
    });

    if (writeOk) {
      successCount.add(1);
      errorRate.add(false);
    } else {
      errorCount.add(1);
      errorRate.add(true);
      consecutiveErrors.add(1);

      // 에러 로깅 (다운타임 분석용)
      console.error(
        `WRITE_FAIL seq=${seq} status=${writeRes.status} ` +
        `ts=${timestamp} duration=${writeRes.timings.duration}ms ` +
        `error=${writeRes.error || 'none'}`
      );
    }
  });

  // 짧은 대기
  sleep(0.05);

  // ==========================================
  // Read Operation (POST 목록 조회)
  // ==========================================
  group('read_operations', function () {
    const readRes = http.get(
      `${config.baseUrl}/groups/${data.groupId}/posts`,
      {
        headers: headers,
        tags: { type: 'read', operation: 'list_posts' },
        timeout: '10s',
      }
    );

    readLatency.add(readRes.timings.duration);

    const readOk = check(readRes, {
      'read status 2xx': (r) => r.status >= 200 && r.status < 300,
    });

    if (readOk) {
      successCount.add(1);
      errorRate.add(false);
    } else {
      errorCount.add(1);
      errorRate.add(true);

      console.error(
        `READ_FAIL seq=${seq} status=${readRes.status} ` +
        `ts=${timestamp} duration=${readRes.timings.duration}ms`
      );
    }
  });

  sleep(0.05);
}

// ==========================================
// Teardown
// ==========================================
export function teardown(data) {
  const endTime = Date.now();
  const totalDuration = (endTime - data.startTime) / 1000;

  console.log('==========================================');
  console.log('Test Summary');
  console.log('==========================================');
  console.log(`Total Duration: ${totalDuration}s`);
  console.log(`Start Time: ${new Date(data.startTime).toISOString()}`);
  console.log(`End Time: ${new Date(endTime).toISOString()}`);
}

// ==========================================
// Handle Summary (결과 저장)
// ==========================================
export function handleSummary(data) {
  const timestamp = new Date().toISOString().replace(/[:.]/g, '-');

  return {
    [`/scripts/results/summary-${timestamp}.json`]: JSON.stringify(data, null, 2),
    stdout: textSummary(data, { indent: ' ', enableColors: true }),
  };
}

// Simple text summary
function textSummary(data, options) {
  const metrics = data.metrics;
  let summary = '\n========== Migration Load Test Results ==========\n\n';

  if (metrics.migration_errors) {
    summary += `Total Errors: ${metrics.migration_errors.values.count}\n`;
  }
  if (metrics.migration_success) {
    summary += `Total Success: ${metrics.migration_success.values.count}\n`;
  }
  if (metrics.error_rate) {
    summary += `Error Rate: ${(metrics.error_rate.values.rate * 100).toFixed(4)}%\n`;
  }
  if (metrics.write_latency) {
    summary += `Write Latency p95: ${metrics.write_latency.values['p(95)'].toFixed(2)}ms\n`;
    summary += `Write Latency p99: ${metrics.write_latency.values['p(99)'].toFixed(2)}ms\n`;
  }
  if (metrics.read_latency) {
    summary += `Read Latency p95: ${metrics.read_latency.values['p(95)'].toFixed(2)}ms\n`;
    summary += `Read Latency p99: ${metrics.read_latency.values['p(99)'].toFixed(2)}ms\n`;
  }

  summary += '\n=================================================\n';
  return summary;
}
