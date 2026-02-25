// ==========================================
// K6 Configuration
// 마이그레이션 테스트용 설정
// ==========================================

export const config = {
  // 타겟 서버 URL (환경변수 또는 기본값)
  baseUrl: __ENV.TARGET_URL || 'http://localhost',

  // 테스트 그룹 ID (실제 운영 그룹 ID로 변경)
  testGroupId: __ENV.TEST_GROUP_ID || '1',

  // 인증 토큰 (실제 토큰으로 변경 필요)
  authToken: __ENV.AUTH_TOKEN || '',

  // QPS 설정
  qps: {
    baseline: 300,      // 기준 QPS
    spike: 500,         // 스파이크 QPS
    warmup: 50,         // 워밍업 QPS
  },

  // 테스트 시간 설정
  duration: {
    baseline: '10m',    // 기준선 측정
    replication: '10m', // 복제 중 테스트
    postCutover: '10m', // 전환 후 테스트
    warmup: '2m',       // 워밍업
  },

  // 허용 기준 (migration-plan.md 기준)
  thresholds: {
    maxDowntimeMs: 3000,    // 최대 다운타임 3초
    maxErrorRate: 0.001,    // 최대 에러율 0.1%
    p95LatencyMs: 500,      // p95 레이턴시 500ms 이하
    p99LatencyMs: 2000,     // p99 레이턴시 2초 이하
  },
};

export default config;