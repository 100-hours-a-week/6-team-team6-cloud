import http from 'k6/http';
import { check, sleep } from 'k6';
import { Counter, Trend, Rate, Gauge } from 'k6/metrics';
import { intEnv, parseOptionalInt, boundedNumEnv, boolEnv } from './lib/env.js';
import { stripTrailingSlash, makeSeed, makeLoginId, hasResponseHeaderValue } from './lib/common.js';

const TARGET_URL = stripTrailingSlash(__ENV.CUTOVER_TARGET_URL || __ENV.TARGET_URL || 'http://test.billages.com/api');
const GROUP_ID = parseOptionalInt(__ENV.CUTOVER_GROUP_ID || __ENV.GROUP_ID) || 1;
const CUTOVER_READ_PROBE_MODE = (__ENV.CUTOVER_READ_PROBE_MODE || 'groups').toLowerCase();

const CUTOVER_RPS = intEnv('CUTOVER_RPS', 300);
const CUTOVER_DURATION = __ENV.CUTOVER_DURATION || '10m';
const CUTOVER_TIMEOUT = __ENV.CUTOVER_TIMEOUT || '5s';
const CUTOVER_WRITE_PROBE_RATIO = boundedNumEnv('CUTOVER_WRITE_PROBE_RATIO', 0.3, 0, 1);
const CUTOVER_INCLUDE_WRITE_PROBE = boolEnv('CUTOVER_INCLUDE_WRITE_PROBE', true);
const CUTOVER_DOWNTIME_PROBE_INTERVAL_MS = intEnv('CUTOVER_DOWNTIME_PROBE_INTERVAL_MS', 200);

const CUTOVER_MAX_ERROR_RATE = boundedNumEnv('CUTOVER_MAX_ERROR_RATE', 0.05, 0, 1);
const CUTOVER_MAX_WRITE_BLOCK_RATE = boundedNumEnv('CUTOVER_MAX_WRITE_BLOCK_RATE', 1.0, 0, 1);
const CUTOVER_MAX_UNPLANNED_DOWNTIME_MS = intEnv('CUTOVER_MAX_UNPLANNED_DOWNTIME_MS', 5000);
const CUTOVER_P95_MS = intEnv('CUTOVER_P95_MS', 3000);

const WRITE_BLOCK_HEADER_NAME = __ENV.CUTOVER_WRITE_BLOCK_HEADER_NAME || __ENV.WRITE_BLOCK_HEADER_NAME || 'X-Migration-Write-Block';
const WRITE_BLOCK_HEADER_VALUE =
  __ENV.CUTOVER_WRITE_BLOCK_HEADER_VALUE || __ENV.WRITE_BLOCK_HEADER_VALUE || 'soft-freeze';

const cutoverErrors = new Counter('cutover_errors');
const cutoverSuccess = new Counter('cutover_success');
const cutoverResponseTime = new Trend('cutover_response_time', true);

const cutoverTotalErrorRate = new Rate('cutover_total_error_rate');
const cutoverReadErrorRate = new Rate('cutover_read_error_rate');
const cutoverWriteBlockedRate = new Rate('cutover_write_block_rate');
const cutoverIntentionalWriteBlockRate = new Rate('cutover_intentional_write_block_rate');
const cutoverUnexpectedWriteFailureRate = new Rate('cutover_unexpected_write_failure_rate');

const cutoverUnplannedDowntimeTotalMs = new Counter('cutover_unplanned_downtime_total_ms');
const cutoverUnplannedDowntimeEventMs = new Trend('cutover_unplanned_downtime_event_ms', true);
const cutoverUnplannedDowntimeEvents = new Counter('cutover_unplanned_downtime_events');

const errorTimestamp = new Gauge('cutover_error_ts');
const recoveryTimestamp = new Gauge('cutover_recovery_ts');

let monitorVuLastHealthy = true;
let timelineLastTs = null;
let timelineDowntimeStartTs = null;
let timelineInDowntime = false;

export const options = {
  scenarios: {
    cutover_monitor: {
      executor: 'constant-arrival-rate',
      rate: CUTOVER_RPS,
      timeUnit: '1s',
      duration: CUTOVER_DURATION,
      preAllocatedVUs: 300,
      maxVUs: 1000,
      exec: 'default',
    },
    cutover_timeline_probe: {
      executor: 'constant-vus',
      vus: 1,
      duration: CUTOVER_DURATION,
      exec: 'timelineProbeScenario',
    },
  },
  thresholds: {
    cutover_total_error_rate: [`rate<${CUTOVER_MAX_ERROR_RATE}`],
    cutover_write_block_rate: [`rate<${CUTOVER_MAX_WRITE_BLOCK_RATE}`],
    cutover_unexpected_write_failure_rate: [`rate<${CUTOVER_MAX_ERROR_RATE}`],
    cutover_response_time: [`p(95)<${CUTOVER_P95_MS}`],
    cutover_unplanned_downtime_total_ms: [`count<${CUTOVER_MAX_UNPLANNED_DOWNTIME_MS}`],
  },
};

export function setup() {
  const staticToken = __ENV.CUTOVER_AUTH_TOKEN || __ENV.AUTH_TOKEN || '';
  const seed = makeSeed();

  console.log('==========================================');
  console.log('CUTOVER MONITOR START');
  console.log('==========================================');
  console.log(`target=${TARGET_URL}`);
  console.log(`groupId=${GROUP_ID}`);
  console.log(`readProbeMode=${CUTOVER_READ_PROBE_MODE}`);
  console.log(`rps=${CUTOVER_RPS} duration=${CUTOVER_DURATION}`);
  console.log(`writeProbe=${CUTOVER_INCLUDE_WRITE_PROBE} ratio=${CUTOVER_WRITE_PROBE_RATIO}`);
  console.log(
    `writeBlockMarker=${WRITE_BLOCK_HEADER_NAME}:${WRITE_BLOCK_HEADER_VALUE} downtimeProbeIntervalMs=${CUTOVER_DOWNTIME_PROBE_INTERVAL_MS}`,
  );

  if (staticToken) {
    console.log('authToken source: env');
    return {
      startTime: Date.now(),
      groupId: GROUP_ID,
      authToken: staticToken,
      probeLoginId: null,
    };
  }

  const probeLoginId = makeLoginId(`cut${seed}`, 0);
  const probePassword = __ENV.CUTOVER_USER_PASSWORD || 'Qwer1234!';

  http.post(
    `${TARGET_URL}/users`,
    JSON.stringify({ loginId: probeLoginId, password: probePassword }),
    { headers: { 'Content-Type': 'application/json' }, timeout: CUTOVER_TIMEOUT },
  );

  const loginRes = http.post(
    `${TARGET_URL}/auth/login`,
    JSON.stringify({ loginId: probeLoginId, password: probePassword }),
    { headers: { 'Content-Type': 'application/json' }, timeout: CUTOVER_TIMEOUT },
  );

  const authToken = loginRes.status === 200 ? loginRes.json('accessToken') : '';
  if (!authToken) {
    console.log('WARNING: probe login failed. monitor will run read-only without auth token.');
  }

  return {
    startTime: Date.now(),
    groupId: GROUP_ID,
    authToken,
    probeLoginId,
  };
}

export default function (data) {
  const ts = Date.now();
  const headers = buildHeaders(data.authToken);

  const readRes = readProbe(data.groupId, headers, 'cutover_read');
  cutoverResponseTime.add(readRes.timings.duration);

  const readOk = check(readRes, {
    'cutover read status is 2xx': (r) => r.status >= 200 && r.status < 300,
  });
  cutoverReadErrorRate.add(!readOk);

  let writeState = {
    blocked: false,
    intentional: false,
    unexpected: false,
  };

  if (CUTOVER_INCLUDE_WRITE_PROBE && data.authToken && Math.random() < CUTOVER_WRITE_PROBE_RATIO) {
    const writeRes = writeProbe(data.groupId, headers);
    const writeOk = writeRes.status === 201;
    writeState = classifyWriteProbe(writeRes, writeOk);
  }

  cutoverWriteBlockedRate.add(writeState.blocked);

  cutoverIntentionalWriteBlockRate.add(writeState.intentional);
  cutoverUnexpectedWriteFailureRate.add(writeState.unexpected);

  const healthy = readOk && !writeState.unexpected;
  cutoverTotalErrorRate.add(!healthy);

  if (healthy) {
    cutoverSuccess.add(1);
    if (!monitorVuLastHealthy) {
      console.log(`RECOVERY ts=${ts} iso=${new Date(ts).toISOString()}`);
      recoveryTimestamp.add(ts);
    }
  } else {
    cutoverErrors.add(1);
    if (monitorVuLastHealthy) {
      console.log(`ERROR_START ts=${ts} iso=${new Date(ts).toISOString()}`);
      errorTimestamp.add(ts);
    }
    console.error(
      `ERROR ts=${ts} readStatus=${readRes.status} writeBlocked=${writeState.blocked} intentional=${writeState.intentional} unexpected=${writeState.unexpected}`,
    );
  }

  monitorVuLastHealthy = healthy;
  sleep(0.01);
}

export function timelineProbeScenario(data) {
  const now = Date.now();
  const headers = buildHeaders(data.authToken);

  if (timelineLastTs !== null && timelineInDowntime) {
    cutoverUnplannedDowntimeTotalMs.add(now - timelineLastTs);
  }

  const readRes = readProbe(data.groupId, headers, 'cutover_timeline_read');
  const unplannedDown = isDowntimeLike(readRes);

  if (unplannedDown && !timelineInDowntime) {
    timelineInDowntime = true;
    timelineDowntimeStartTs = now;
    cutoverUnplannedDowntimeEvents.add(1);
    errorTimestamp.add(now);
    console.log(`TIMELINE_DOWN_START ts=${now} status=${readRes.status}`);
  }

  if (!unplannedDown && timelineInDowntime) {
    const duration = now - timelineDowntimeStartTs;
    cutoverUnplannedDowntimeEventMs.add(duration);
    recoveryTimestamp.add(now);
    timelineInDowntime = false;
    timelineDowntimeStartTs = null;
    console.log(`TIMELINE_RECOVERY ts=${now} downtimeMs=${duration}`);
  }

  timelineLastTs = now;
  sleep(CUTOVER_DOWNTIME_PROBE_INTERVAL_MS / 1000);
}

function buildHeaders(authToken) {
  const headers = {
    'Content-Type': 'application/json',
  };

  if (authToken) {
    headers.Authorization = `Bearer ${authToken}`;
  }

  return headers;
}

function readProbe(groupId, headers, tagType) {
  let path = `/groups/${groupId}/posts`;
  if (CUTOVER_READ_PROBE_MODE === 'profile') {
    path = '/users/me';
  } else if (CUTOVER_READ_PROBE_MODE === 'health') {
    path = '/actuator/health';
  }

  return http.get(`${TARGET_URL}${path}`, {
    headers,
    timeout: CUTOVER_TIMEOUT,
    tags: { type: tagType },
  });
}

function writeProbe(groupId, headers) {
  const nonce = `${Date.now()}-${Math.floor(Math.random() * 10000)}`;

  return http.post(
    `${TARGET_URL}/groups/${groupId}/posts`,
    JSON.stringify({
      title: `load-test-cutover-${nonce}`.slice(0, 50),
      content: `cutover probe ${nonce}`,
      imageUrls: [`load-test/cutover/${nonce}.jpg`],
      rentalFee: 1000,
      feeUnit: 'DAY',
    }),
    {
      headers,
      timeout: CUTOVER_TIMEOUT,
      tags: { type: 'cutover_write_probe' },
    },
  );
}

function classifyWriteProbe(res, writeOk) {
  if (writeOk) {
    return {
      blocked: false,
      intentional: false,
      unexpected: false,
    };
  }

  const intentional =
    res.status === 503 &&
    hasResponseHeaderValue(res, WRITE_BLOCK_HEADER_NAME, WRITE_BLOCK_HEADER_VALUE);

  return {
    blocked: true,
    intentional,
    unexpected: !intentional,
  };
}

function isDowntimeLike(res) {
  return res.status === 0 || res.status >= 500;
}

export function teardown(data) {
  const end = Date.now();
  const sec = ((end - data.startTime) / 1000).toFixed(1);

  console.log('==========================================');
  console.log('CUTOVER MONITOR END');
  console.log('==========================================');
  console.log(`duration=${sec}s`);
  console.log('지표 확인: cutover_unplanned_downtime_total_ms / cutover_unplanned_downtime_event_ms');
  console.log('의도 차단 분리: cutover_intentional_write_block_rate / cutover_unexpected_write_failure_rate');
  console.log('==========================================');
}
