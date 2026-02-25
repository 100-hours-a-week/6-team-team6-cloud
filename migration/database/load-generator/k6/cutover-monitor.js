import http from 'k6/http';
import { check, sleep } from 'k6';
import { Counter, Trend, Rate } from 'k6/metrics';
import { config } from './config.js';

// ==========================================
// Cutover Monitoring Script
// 전환 중 다운타임 정밀 측정용
// ==========================================

const errorCount = new Counter('cutover_errors');
const successCount = new Counter('cutover_success');
const responseTime = new Trend('cutover_response_time', true);
const errorRate = new Rate('cutover_error_rate');

// 연속 에러/성공 추적
let consecutiveErrorStart = null;
let consecutiveErrors = 0;
let maxConsecutiveErrors = 0;
let downtimeStart = null;
let downtimeEnd = null;

export const options = {
  scenarios: {
    cutover_monitor: {
      executor: 'constant-arrival-rate',
      rate: config.qps.baseline,
      timeUnit: '1s',
      duration: '10m',  // 전환 전후로 충분히
      preAllocatedVUs: 500,
      maxVUs: 1000,
    },
  },
};

export function setup() {
  console.log('==========================================');
  console.log('Cutover Monitoring Started');
  console.log(`Target: ${config.baseUrl}`);
  console.log(`QPS: ${config.qps.baseline}`);
  console.log('==========================================');

  return {
    startTime: Date.now(),
    groupId: config.testGroupId,
  };
}

export default function (data) {
  const timestamp = Date.now();
  const headers = {
    'Content-Type': 'application/json',
  };

  if (config.authToken) {
    headers['Authorization'] = `Bearer ${config.authToken}`;
  }

  // Health check 스타일의 빠른 요청
  const res = http.get(
    `${config.baseUrl}/groups/${data.groupId}/posts?size=1`,
    {
      headers: headers,
      timeout: '5s',
      tags: { type: 'cutover_check' },
    }
  );

  responseTime.add(res.timings.duration);

  const isOk = res.status >= 200 && res.status < 300;

  if (isOk) {
    successCount.add(1);
    errorRate.add(false);

    // 에러에서 복구됨
    if (consecutiveErrors > 0) {
      downtimeEnd = timestamp;
      const downtime = downtimeEnd - downtimeStart;
      console.log(`RECOVERY at ${new Date(timestamp).toISOString()}`);
      console.log(`Downtime: ${downtime}ms (${consecutiveErrors} consecutive errors)`);

      if (consecutiveErrors > maxConsecutiveErrors) {
        maxConsecutiveErrors = consecutiveErrors;
      }
      consecutiveErrors = 0;
      consecutiveErrorStart = null;
    }
  } else {
    errorCount.add(1);
    errorRate.add(true);
    consecutiveErrors++;

    if (consecutiveErrorStart === null) {
      consecutiveErrorStart = timestamp;
      downtimeStart = timestamp;
      console.log(`ERROR_START at ${new Date(timestamp).toISOString()}`);
    }

    // 실시간 로깅
    console.error(
      `ERROR #${consecutiveErrors} ts=${timestamp} ` +
      `status=${res.status} duration=${res.timings.duration}ms`
    );
  }

  // 빠른 폴링
  sleep(0.01);
}

export function teardown(data) {
  const endTime = Date.now();
  const totalDuration = (endTime - data.startTime) / 1000;

  console.log('\n==========================================');
  console.log('Cutover Monitoring Summary');
  console.log('==========================================');
  console.log(`Total Duration: ${totalDuration}s`);

  if (downtimeStart && downtimeEnd) {
    const totalDowntime = downtimeEnd - downtimeStart;
    console.log(`Measured Downtime: ${totalDowntime}ms`);
    console.log(`Max Consecutive Errors: ${maxConsecutiveErrors}`);

    if (totalDowntime <= config.thresholds.maxDowntimeMs) {
      console.log(`PASS: Downtime within threshold (${config.thresholds.maxDowntimeMs}ms)`);
    } else {
      console.log(`FAIL: Downtime exceeded threshold (${config.thresholds.maxDowntimeMs}ms)`);
    }
  } else if (consecutiveErrors > 0) {
    console.log(`WARNING: Test ended with ${consecutiveErrors} consecutive errors`);
    console.log('Service may still be down');
  } else {
    console.log('No downtime detected during test period');
  }
  console.log('==========================================');
}

export function handleSummary(data) {
  const timestamp = new Date().toISOString().replace(/[:.]/g, '-');

  return {
    [`/scripts/results/cutover-${timestamp}.json`]: JSON.stringify(data, null, 2),
  };
}