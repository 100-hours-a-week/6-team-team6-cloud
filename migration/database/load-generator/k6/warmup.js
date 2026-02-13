import http from 'k6/http';
import { check, sleep } from 'k6';
import { Counter, Rate } from 'k6/metrics';
import { config } from './config.js';

// ==========================================
// Warmup Script (읽기 전용)
// 전환 전 Target 서버 커넥션 풀 예열용
//
// ⚠️ 중요: 이 스크립트는 GET 요청만 수행합니다.
// 쓰기 요청(POST/PUT/DELETE)은 절대 금지!
// RDS가 아직 replica 상태이므로 쓰기 시 데이터 불일치 발생
// ==========================================

const warmupSuccess = new Counter('warmup_success');
const warmupErrors = new Counter('warmup_errors');
const warmupErrorRate = new Rate('warmup_error_rate');

export const options = {
  scenarios: {
    warmup: {
      executor: 'constant-arrival-rate',
      rate: config.qps.warmup,  // 50 QPS
      timeUnit: '1s',
      duration: config.duration.warmup,  // 2분
      preAllocatedVUs: 100,
      maxVUs: 200,
    },
  },
  thresholds: {
    'http_req_duration': ['p(95)<1000'],
    'warmup_error_rate': ['rate<0.01'],
  },
};

export function setup() {
  // Target URL은 환경변수로 전달 (RDS 연결 앱, 포트 8081)
  const targetUrl = __ENV.WARMUP_TARGET_URL || config.baseUrl;

  console.log('==========================================');
  console.log('WARMUP SCRIPT - READ ONLY');
  console.log('==========================================');
  console.log(`Target: ${targetUrl}`);
  console.log(`QPS: ${config.qps.warmup}`);
  console.log(`Duration: ${config.duration.warmup}`);
  console.log('');
  console.log('⚠️  WARNING: This script performs GET requests ONLY');
  console.log('⚠️  NO write operations (POST/PUT/DELETE) allowed');
  console.log('⚠️  RDS is still a replica - writes would cause data inconsistency');
  console.log('==========================================');

  return {
    targetUrl: targetUrl,
    groupId: config.testGroupId,
  };
}

export default function (data) {
  const headers = {
    'Content-Type': 'application/json',
  };

  if (config.authToken) {
    headers['Authorization'] = `Bearer ${config.authToken}`;
  }

  // ==========================================
  // 읽기 요청만 수행 (GET)
  // 쓰기 요청은 절대 금지!
  // ==========================================

  // 1. 게시글 목록 조회
  const listRes = http.get(
    `${data.targetUrl}/groups/${data.groupId}/posts`,
    {
      headers: headers,
      timeout: '10s',
      tags: { type: 'read', operation: 'list' },
    }
  );

  const listOk = check(listRes, {
    'list status 2xx': (r) => r.status >= 200 && r.status < 300,
  });

  if (listOk) {
    warmupSuccess.add(1);
    warmupErrorRate.add(false);
  } else {
    warmupErrors.add(1);
    warmupErrorRate.add(true);
    console.error(`WARMUP_ERROR: list status=${listRes.status}`);
  }

  sleep(0.05);

  // 2. 특정 게시글 상세 조회 (있을 경우)
  // 존재하지 않는 ID여도 404는 정상 응답으로 처리
  const detailRes = http.get(
    `${data.targetUrl}/groups/${data.groupId}/posts/1`,
    {
      headers: headers,
      timeout: '10s',
      tags: { type: 'read', operation: 'detail' },
    }
  );

  // 404도 커넥션 풀 예열 목적으로는 유효
  const detailOk = check(detailRes, {
    'detail status 2xx or 404': (r) => (r.status >= 200 && r.status < 300) || r.status === 404,
  });

  if (detailOk) {
    warmupSuccess.add(1);
    warmupErrorRate.add(false);
  } else {
    warmupErrors.add(1);
    warmupErrorRate.add(true);
  }

  sleep(0.05);

  // ==========================================
  // ⚠️ 아래는 절대 실행하지 않음
  // 쓰기 요청 예시 (주석 처리됨, 실행 금지)
  // ==========================================
  //
  // http.post(...)  // ❌ 금지
  // http.put(...)   // ❌ 금지
  // http.patch(...) // ❌ 금지
  // http.del(...)   // ❌ 금지
  //
}

export function teardown(data) {
  console.log('');
  console.log('==========================================');
  console.log('WARMUP COMPLETED');
  console.log('==========================================');
  console.log('Connection pool should now be warmed up.');
  console.log('JVM JIT should be primed for common code paths.');
  console.log('');
  console.log('Next steps:');
  console.log('  1. Verify Lag = 0 on RDS');
  console.log('  2. SET GLOBAL read_only = ON on source');
  console.log('  3. Check SHOW PROCESSLIST for pending transactions');
  console.log('  4. Execute Nginx upstream switch');
  console.log('==========================================');
}