import http from 'k6/http';
import { check, sleep } from 'k6';
import { Counter, Rate, Trend } from 'k6/metrics';
import { intEnv, parseOptionalInt, boundedNumEnv } from './lib/env.js';
import { makeLoginId, makeSeed, stripTrailingSlash } from './lib/common.js';

const TARGET_URL = stripTrailingSlash(__ENV.WARMUP_TARGET_URL || __ENV.TARGET_URL || 'http://test.billages.com/api');
const GROUP_ID = parseOptionalInt(__ENV.WARMUP_GROUP_ID || __ENV.GROUP_ID) || 1;
const AUTH_TOKEN = __ENV.WARMUP_AUTH_TOKEN || __ENV.AUTH_TOKEN || '';
const WARMUP_USER_PASSWORD = __ENV.WARMUP_USER_PASSWORD || __ENV.USER_PASSWORD || 'Qwer1234!';

const WARMUP_RPS = intEnv('WARMUP_RPS', 20);
const WARMUP_DURATION = __ENV.WARMUP_DURATION || '2m';
const WARMUP_TIMEOUT = __ENV.WARMUP_TIMEOUT || '15s';
const WARMUP_PRE_ALLOCATED_VUS = intEnv('WARMUP_PRE_ALLOCATED_VUS', 30);
const WARMUP_MAX_VUS = intEnv('WARMUP_MAX_VUS', 120);
const WARMUP_MAX_ERROR_RATE = boundedNumEnv('WARMUP_MAX_ERROR_RATE', 0.01, 0, 1);
const WARMUP_P95_MS = intEnv('WARMUP_P95_MS', 1000);

const warmupSuccess = new Counter('warmup_success');
const warmupErrors = new Counter('warmup_errors');
const warmupErrorRate = new Rate('warmup_error_rate');
const warmupLatency = new Trend('warmup_latency', true);

export const options = {
  scenarios: {
    warmup_read_only: {
      executor: 'constant-arrival-rate',
      rate: WARMUP_RPS,
      timeUnit: '1s',
      duration: WARMUP_DURATION,
      preAllocatedVUs: WARMUP_PRE_ALLOCATED_VUS,
      maxVUs: Math.max(WARMUP_PRE_ALLOCATED_VUS, WARMUP_MAX_VUS),
    },
  },
  thresholds: {
    warmup_error_rate: [`rate<${WARMUP_MAX_ERROR_RATE}`],
    warmup_latency: [`p(95)<${WARMUP_P95_MS}`],
  },
};

export function setup() {
  let authToken = AUTH_TOKEN;
  let authTokenSource = 'env';

  if (!authToken) {
    authTokenSource = 'auto-login';
    const loginId = makeLoginId(`w${makeSeed()}`, 0);

    http.post(
      `${TARGET_URL}/users`,
      JSON.stringify({ loginId, password: WARMUP_USER_PASSWORD }),
      { headers: { 'Content-Type': 'application/json' }, timeout: WARMUP_TIMEOUT },
    );

    const loginRes = http.post(
      `${TARGET_URL}/auth/login`,
      JSON.stringify({ loginId, password: WARMUP_USER_PASSWORD }),
      { headers: { 'Content-Type': 'application/json' }, timeout: WARMUP_TIMEOUT },
    );

    if (loginRes.status === 200) {
      authToken = loginRes.json('accessToken') || '';
    } else {
      authTokenSource = 'none';
      console.log(`[WARMUP] WARNING: auto-login failed status=${loginRes.status}`);
    }
  }

  console.log('==========================================');
  console.log('WARMUP (READ ONLY)');
  console.log('==========================================');
  console.log(`target=${TARGET_URL}`);
  console.log(`groupId=${GROUP_ID}`);
  console.log(
    `rps=${WARMUP_RPS} duration=${WARMUP_DURATION} preVUs=${WARMUP_PRE_ALLOCATED_VUS} maxVUs=${Math.max(WARMUP_PRE_ALLOCATED_VUS, WARMUP_MAX_VUS)}`,
  );
  console.log(`authTokenSource=${authTokenSource}`);
  console.log('POST/PUT/PATCH/DELETE는 warmup에서 수행하지 않음');
  console.log('==========================================');

  return {
    targetUrl: TARGET_URL,
    groupId: GROUP_ID,
    authToken,
  };
}

export default function (data) {
  const headers = {
    'Content-Type': 'application/json',
  };

  if (data.authToken) {
    headers.Authorization = `Bearer ${data.authToken}`;
  }

  const branch = Math.random();
  let res;

  if (branch < 0.6) {
    res = http.get(`${data.targetUrl}/groups/${data.groupId}/posts`, { headers, timeout: WARMUP_TIMEOUT, tags: { action: 'list' } });
  } else if (branch < 0.9) {
    res = http.get(`${data.targetUrl}/groups/${data.groupId}/posts/1`, { headers, timeout: WARMUP_TIMEOUT, tags: { action: 'detail' } });
  } else {
    res = http.get(`${data.targetUrl}/users/me`, { headers, timeout: WARMUP_TIMEOUT, tags: { action: 'profile' } });
  }

  warmupLatency.add(res.timings.duration);

  const ok = check(res, {
    'warmup status is 2xx or 404': (r) => (r.status >= 200 && r.status < 300) || r.status === 404,
  });

  if (ok) {
    warmupSuccess.add(1);
    warmupErrorRate.add(false);
  } else {
    warmupErrors.add(1);
    warmupErrorRate.add(true);
  }

  sleep(0.05);
}

export function teardown() {
  console.log('==========================================');
  console.log('WARMUP COMPLETED');
  console.log('다음 단계: lag=0 확인 후 cutover 실행');
  console.log('==========================================');
}
