# Billage 데이터베이스 마이그레이션 계획서 (v2.0)

## 0. 문서 상태

- 문서 성격: **실행 기준 문서(구버전 대체)**
- 작성일: 2024-02-10 (v1.0)
- 전면 개정일: **2026-02-13 (v2.0)**
- 적용 범위: Dev 리허설 + Prod 실행
- 기준 런북: `context/migration/db-migration-runbook.md`

> 이 문서는 기존 `v1.0`의 다중 전략(Option A/B) 서술을 폐기하고,  
> **Replica 기반 무중단 전환 전략 1개로 단일화**한다.

---

## 1. 개요

Billage 인프라 마이그레이션에서 DB 전환은 선행 필수 단계다.  
Backend/FastAPI가 DB에 직접 의존하므로, DB 전환이 안정적으로 완료되어야 이후 WAS/트래픽 전환을 진행할 수 있다.

핵심 목표:
- Host MySQL(EC2) → RDS MySQL 8.0 전환
- 데이터 정합성 100% 보장
- 사용자 체감 중단 최소화(무중단에 가깝게)
- 전환 실패 시 신속 롤백 가능

---

## 2. 전략 단일화 (중요)

### 2.1 최종 전략

**MySQL Replication 기반 무중단 전환**을 유일한 실행 전략으로 채택한다.

전략 요약:
1. Host MySQL에서 `mysqldump --single-transaction` 수행 + `gtid_executed` 기준점 확보
2. RDS를 Host MySQL의 external replica로 설정
3. `Seconds_Behind_Source=0` 도달까지 추적
4. 짧은 Write Freeze 동안 트래픽을 Host WAS(8080)에서 RDS WAS(8081)로 전환
5. 전환 후 replication 정리 및 최종 검증

### 2.2 폐기/비적용 항목

아래 항목은 더 이상 본 문서의 실행 기준이 아니다:
- Option A vs Option B 의사결정 분기
- mysqldump 단독 컷오버(중단 시간 중심) 시나리오
- DMS 도입 검토를 기본 경로로 두는 계획

필요 시 DMS는 “별도 RFC/별도 문서”로 다룬다.

---

## 3. 현재 진행 현황 (2026-02-13 기준)

출처: `context/migration/db-migration-runbook.md`

- 리허설 EC2 준비: 완료
- 대용량 시딩(약 1.78GB): 완료
- WAS 8080/8081 이중 구성: 완료
- Nginx 스위칭 스크립트: 완료
- RDS 연결 테스트: 완료
- 실측 기반 Round 기록표(부하별 결과): **작성 필요**
- Prod 실행 타임라인 확정: **미완료**

정리:
- **환경 준비는 완료**
- **실행 증빙(리허설 실측 데이터)과 Prod 확정 단계가 남아 있음**

---

## 4. 아키텍처 전환 모델

Source:
- Host MySQL (EC2 내부)
- App 주 연결: Host

Target:
- RDS MySQL 8.0 (Private Subnet)
- App 주 연결: RDS
- Host MySQL: 전환 후 2주간 유지(롤백 버퍼)

데이터 흐름:
1. 초기 덤프 이관
2. Replication 실시간 동기화
3. Lag=0 시점 전환
4. RDS Primary 고정

---

## 5. 실행 원칙

1. **데이터 무결성 우선**: 성능 저하보다 불일치를 더 치명적으로 판단
2. **측정 기반 의사결정**: 추정이 아닌 실측 지표로 Go/No-Go 결정
3. **짧은 전환 구간**: Write Freeze는 초 단위로 관리
4. **즉시 롤백 가능성 유지**: Host MySQL/파라미터 복구 경로 항상 확보

---

## 6. 사전 준비 체크리스트

### 6.1 인프라

- [ ] `shared/rds/dev/` Terraform 적용 및 상태 확인
- [ ] RDS `available`, backup retention 7일 확인
- [ ] DB subnet/security group 점검
- [ ] Host MySQL GTID/Replication 설정(`gtid_mode`, `enforce_gtid_consistency`, `log_bin`, `server_id`) 확인

### 6.2 애플리케이션/운영

- [ ] WAS 8080(Host DB) 정상
- [ ] WAS 8081(RDS DB) 정상
- [ ] Nginx 스위칭 스크립트 테스트 완료
- [ ] 모니터링 대시보드/Grafana/CloudWatch 접근 가능
- [ ] 부하도구(k6) 및 검증 스크립트 준비

### 6.3 계정/접속

- [ ] 리허설/운영 서버 SSH 계정은 **`ubuntu`**로 통일
- [ ] 키/접속 절차 팀 공통화

예시:
```bash
ssh -i ~/.ssh/<key>.pem ubuntu@<host_or_eip>
```

---

## 7. 표준 실행 절차 (요약)

상세 명령어는 `context/migration/db-migration-runbook.md`를 따른다.
컷오버 상세는 `context/migration/08-cutover-runbook.md`를 따른다.

1. 사전 상태 확인 + 기준선 수집
2. 초기 dump 수행(`--single-transaction` + 필요 시 `gzip`)
3. RDS import
4. Replication 시작(`rds_set_external_source_gtid_purged` + `rds_set_external_master_with_auto_position` + `rds_start_replication`)
5. Replica Lag 모니터링(`SHOW REPLICA STATUS`)
6. **2단계 Write Freeze (Lag=0 확인 후)**
   - Soft Freeze: WAS 8080 정지 (`./soft-freeze.sh on`)
   - Hard Freeze: MySQL read_only (`./hard-freeze.sh on`)
7. Nginx 스위칭 8080→8081 (`./switch-backend.sh rds`)
8. 즉시 헬스체크 + 데이터 검증
9. Replication 정리 후 RDS Primary 운영
10. 전환 후 1시간/24시간/1주일 관찰

### 7.1 Write Freeze 전략 (Defense in Depth)

```
┌─────────────────────────────────────────────────────────────┐
│  Soft Freeze (Nginx/WAS)    │  Hard Freeze (DB)            │
├─────────────────────────────┼──────────────────────────────┤
│  - WAS 8080 정지            │  - read_only=ON              │
│  - 사용자 write 차단        │  - 배치/크론/내부호출 차단   │
│  - UX 보호, DB 부하 감소    │  - 정합성 100% 보장          │
└─────────────────────────────┴──────────────────────────────┘
```

> **핵심**: Nginx 차단만으로는 배치/크론/내부호출을 못 막음.
> DB read_only가 "최종 안전장치"로 정합성을 보장함.

---

## 8. 대용량 이관 최적화 포인트 (포트폴리오)

### 8.1 GTID 기준 복제 (Position 대신)

- 본 프로젝트는 `binlog file/position` 고정 방식 대신 **GTID auto-position**을 표준으로 사용한다.
- 이유:
  - 재시작/재시도 시 복제 지점 관리가 단순하다.
  - 운영 절차에서 수동 position 입력 오류를 줄일 수 있다.
  - 포트폴리오 관점에서 “확장 가능한 복제 전략”을 설명하기 좋다.
- RDS MySQL 8.0 기준 절차:
  - `mysql.rds_set_external_source_gtid_purged(...)`
  - `mysql.rds_set_external_master_with_auto_position(...)`
  - (`rds_set_external_source_gtid_purged` 호출 전 `autocommit=1` 권장)
- RDS MySQL 8.4는 용어 변경에 따라 `...source_with_auto_position(...)` 절차를 사용한다.

### 8.2 Dump/Import 성능 최적화

- **`--single-transaction` 사용(필수)**:
  - 서비스 중단 없이 일관된 스냅샷 덤프 가능
  - 단, 덤프 중 DDL(ALTER/DROP/CREATE) 금지 운영 규칙 필요
- **gzip 압축 사용(권장)**:
  - 대용량에서 전송 시간 절감 효과가 큼
  - CPU 사용량 증가와의 트레이드오프를 함께 기록
- **인덱스/FK 후처리(조건부)**:
  - 데이터 10GB+ 또는 대량 INSERT 구간에서는
    “데이터 우선 적재 후 인덱스/FK 생성”이 유리할 수 있음
  - 다만 InnoDB 특성/운영 복잡도 증가를 감안해 사전 리허설 필수

### 8.3 CLI vs GUI 도구 포지셔닝

- 운영 컷오버 표준: **CLI Runbook 우선**
  - 재현성, 감사추적, 자동화 용이성 측면에서 유리
- GUI 도구(DBeaver 등): **보조 수단**
  - 테이블 단위 점검/선별 이관 검토, 탐색형 검증에 활용
  - 운영 본절차의 단일 기준은 아님

### 8.4 실측 지표(포트폴리오 필수)

- Dump 시간, Import 시간, Lag=0 도달 시간
- Write Freeze 시간, 전환 직후 에러율, p95 응답시간
- 정합성 검증 결과(Row count/Checksum)
- 롤백 리허설 시간(RTO)

---

## 9. 검증 기준 (필수)

### 9.1 데이터

- [ ] 테이블 목록 일치
- [ ] 핵심 테이블 Row count 일치
- [ ] Checksum 비교 통과
- [ ] 샘플 조회/쓰기 동작 정상

### 9.2 서비스

- [ ] `/actuator/health` 정상
- [ ] 주요 API 200 응답
- [ ] 전환 직후 5xx 급증 없음

### 9.3 성능

- [ ] p95/에러율이 기준선 대비 허용 범위
- [ ] 전환 중 요청 손실이 허용치 이내

---

## 10. Go / No-Go 기준

Go:
- 모든 필수 검증 통과
- 데이터 불일치 없음
- Lag=0 기반 전환 성공
- 롤백 절차 사전 검증 완료

No-Go:
- 데이터 검증 실패
- 핵심 API 불안정
- 전환 시간/에러율이 임계 초과
- 운영팀 역할 분담/모니터링 준비 미완료

---

## 11. 롤백 원칙

롤백 상세 절차는 아래 문서를 단일 기준으로 사용:
- `context/migration/07-rollback-runbook.md`

핵심:
- PNR 이전: 즉시 복원 가능
- PNR 이후: SSM/엔드포인트 복구 + 앱 재시작 + 데이터 차이 검증
- 전환 후 2주간 Host MySQL 유지

---

## 12. 마일스톤 연계

본 문서 완료 판정은 `M7 (MySQL → RDS)` 완료 조건과 동일하게 본다.

완료 조건:
- [ ] RDS 데이터 이전 완료
- [ ] 검증 자동화/수동 검증 PASS
- [ ] 앱이 RDS 연결로 정상 운영
- [ ] 리허설 기록 보존

선행/후행:
- 선행: RDS/앱 연결 준비
- 후행: 트래픽 전환(M8)

---

## 13. 당장 해야 할 일

1. 리허설 Round별 실측 결과(시간/에러율/p95/Lag)를 런북에 채운다.
2. Go/No-Go 회의에서 Prod 실행 시간(절대 시각) 확정한다.
3. Prod 실행 섹션(Part 7)을 실측값 기반으로 고정한다.
4. 마일스톤 M7 체크 상태를 문서와 동기화한다.

---

## 14. 관련 문서

- 실행 런북: `context/migration/db-migration-runbook.md`
- **컷오버 런북: `context/migration/08-cutover-runbook.md`** (2단계 Freeze 상세)
- 통합 롤백: `context/migration/07-rollback-runbook.md`
- 트러블슈팅: `docs/troubleshooting/DB_MIGRATION_TROUBLESHOOTING.md`
- 리허설 보고서: `docs/report/DB_MIGRATION_REHEARSAL_REPORT.md`
- 전체 마일스톤: `context/v2-migration-milestone.md`
- WAS 전환: `context/migration/03-was-migration.md`
- LB/트래픽 전환: `context/migration/05-lb-traffic-migration.md`

---

## 15. 변경 이력

- v1.0 (2024-02-10): 초기 계획서(다중 전략 비교 중심)
- v2.0 (2026-02-13): **Replica 기반 단일 전략으로 전면 개정**
