# Billage 서비스 무중단 DB 마이그레이션 사례 연구

## 서문

이 문서는 Billage 서비스의 Host MySQL(EC2)에서 AWS RDS로의 데이터베이스 마이그레이션 과정을 기술한다. 단순한 작업 로그가 아닌, 의사결정 과정과 기술적 고민, 그리고 문제 해결 과정을 중심으로 서술한다.

---

## 1. 왜 RDS로 마이그레이션 하는가?

### 1.1 현재 상태의 문제점

기존 아키텍처에서 MySQL은 EC2 인스턴스 내부에서 직접 운영되고 있었다. 이 구조는 초기 개발 단계에서는 간편했지만, 서비스가 성장하면서 몇 가지 운영상의 부담이 드러났다.

**백업과 복구의 복잡성**: EC2 내부 MySQL의 백업은 수동으로 mysqldump를 실행하거나 EBS 스냅샷에 의존해야 했다. 자동화된 백업 정책을 구현하려면 별도의 스크립트와 스케줄러를 관리해야 했고, 특정 시점 복구(Point-in-Time Recovery)는 사실상 불가능했다.

**스케일링의 한계**: MySQL이 EC2와 강하게 결합되어 있어, DB 리소스만 독립적으로 스케일링하기 어려웠다. CPU나 메모리가 부족하면 EC2 인스턴스 전체를 변경해야 했고, 이는 WAS에도 영향을 미쳤다.

**고가용성 부재**: 단일 EC2에서 운영되므로, 인스턴스 장애 시 서비스 전체가 중단되는 위험이 있었다. Multi-AZ 구성을 직접 구현하는 것은 복잡도가 높았다.

### 1.2 RDS 선택 이유

AWS RDS는 이러한 문제들을 관리형 서비스로 해결한다. 자동 백업, 손쉬운 스케일링, Multi-AZ 옵션, 자동 패치 등이 기본 제공된다. 물론 비용이 증가하지만, 운영 부담 감소와 안정성 향상을 고려하면 합리적인 트레이드오프라고 판단했다.

다만 RDS 선택이 끝이 아니었다. 핵심 질문은 "어떻게 서비스 중단 없이 마이그레이션할 것인가?"였다.

---

## 2. 마이그레이션 전략 선택: 왜 Replication인가?

### 2.1 고려했던 선택지들

마이그레이션 전략은 크게 세 가지를 검토했다.

**Option A: 단순 덤프 & 복원**

가장 직관적인 방법이다. 서비스를 일시 중단하고, mysqldump로 전체 데이터를 추출한 뒤, RDS에 import하고, 애플리케이션 연결을 변경한다.

문제는 중단 시간이다. 우리 데이터는 약 1.78GB였고, 덤프에 수 분, import에 또 수 분이 소요된다. 거기에 검증 시간까지 더하면 최소 10-20분의 서비스 중단이 예상되었다. 300K MAU 서비스에서 이 정도 중단은 사용자 경험에 심각한 영향을 미친다.

**Option B: AWS DMS (Database Migration Service)**

AWS가 제공하는 관리형 마이그레이션 서비스다. CDC(Change Data Capture) 기능으로 지속적인 동기화가 가능하다.

그러나 DMS는 별도의 복제 인스턴스를 필요로 하고, 설정이 복잡하며, 우리 규모에서는 오버엔지니어링으로 느껴졌다. 또한 MySQL 네이티브 Replication에 비해 미세한 지연이나 데이터 변환 이슈가 발생할 수 있다는 점도 고려했다.

**Option C: MySQL Replication 기반 전환**

MySQL 자체의 Replication 기능을 활용한다. Host MySQL을 Source로, RDS를 Replica로 구성한 뒤, 실시간으로 데이터를 동기화한다. Replica Lag이 0이 되는 순간 트래픽을 전환하면 된다.

이 방식은 중단 시간을 "초 단위"로 줄일 수 있다. MySQL 네이티브 기능이므로 추가 비용이 없고, 데이터 정합성도 보장된다.

### 2.2 최종 결정

**MySQL Replication 기반 전환을 채택했다.**

결정적인 이유는 "Write Freeze 시간의 최소화"였다. Replication이 실시간으로 동기화되므로, 최종 전환 시점에는 아주 짧은 시간(이상적으로는 1-2초) 동안만 쓰기를 차단하면 된다.

물론 이 방식에도 복잡성이 있다. GTID 설정, Replication 사용자 관리, 에러 처리 등을 직접 다뤄야 한다. 하지만 이 복잡성은 "한 번 설정하면 끝"이고, 서비스 중단은 "매 마이그레이션마다 발생"한다. 장기적으로 Replication 방식이 유리했다.

---

## 3. GTID 기반 Replication을 선택한 이유

### 3.1 전통적 방식의 문제점

MySQL Replication은 전통적으로 binlog 파일명과 position을 기반으로 동작한다. "binlog.000052의 1234 position부터 복제해라"라는 식이다.

이 방식의 문제는 관리가 번거롭다는 점이다. 장애 복구 시 정확한 position을 찾아야 하고, Source가 변경되면 position도 달라진다. 사람이 개입할 여지가 많아지면 실수 가능성도 높아진다.

### 3.2 GTID의 장점

GTID(Global Transaction Identifier)는 각 트랜잭션에 고유 ID를 부여한다. "어느 서버에서 몇 번째로 실행된 트랜잭션인지"가 ID에 담긴다. Replica는 단순히 "이 GTID까지 받았으니, 그 다음부터 보내달라"고 요청하면 된다.

이 방식은 여러 이점이 있다:

- **자동 position 관리**: 복제 지점을 수동으로 지정할 필요가 없다.
- **장애 복구 용이**: 재시작 후에도 어디서부터 이어받을지 자동으로 결정된다.
- **운영 실수 감소**: position 입력 오류 같은 휴먼 에러가 줄어든다.

### 3.3 RDS에서의 GTID 제약

한 가지 난관이 있었다. RDS MySQL에서는 `gtid_mode` 파라미터를 직접 수정할 수 없다. Terraform으로 설정하려 했을 때 다음 에러가 발생했다:

```
Error: The parameter gtid_mode cannot be modified.
```

처음에는 당황했다. "GTID를 못 쓰면 전통적 방식으로 해야 하나?"라는 생각이 들었다.

그러나 문서를 더 조사해보니, RDS가 `OFF_PERMISSIVE` 모드라도 Source(Host MySQL)가 GTID 기반이면 GTID 트랜잭션을 수신할 수 있음을 알게 되었다. 핵심은 Source의 `gtid_mode=ON`이지, Replica의 gtid_mode가 아니었다.

결국 RDS Parameter Group에서 `gtid_mode`는 건드리지 않고, `enforce_gtid_consistency=ON`과 `binlog_format=ROW`만 설정하여 문제를 해결했다. 이 경험은 "에러 메시지만 보고 포기하지 말고, 실제 동작 방식을 이해하라"는 교훈을 주었다.

---

## 4. 데이터 정합성에 대한 고민

### 4.1 "100% 데이터 일치"란 무엇인가

마이그레이션에서 가장 중요한 것은 데이터 정합성이다. "한 건의 데이터도 누락되거나 중복되어서는 안 된다."

그런데 "정합성"을 어떻게 검증할 것인가? 단순히 테이블 Row Count만 비교하면 될까?

우리는 여러 층위의 검증을 설계했다:

1. **Row Count 비교**: 가장 기본적인 검증. 모든 테이블의 행 수가 일치해야 한다.
2. **실시간 복제 테스트**: Host에 INSERT 후 RDS에서 즉시 조회되는지 확인.
3. **Lag 모니터링**: `Seconds_Behind_Source`가 0인지 지속 확인.
4. **샘플 데이터 검증**: 특정 레코드를 양쪽에서 조회하여 값 비교.

### 4.2 Write Freeze의 필요성

Replication이 아무리 빨라도, 쓰기 요청이 계속 들어오면 영원히 "완전 동기화"에 도달할 수 없다. Replica가 따라잡기 전에 새로운 데이터가 들어오기 때문이다.

따라서 최종 전환 직전에는 반드시 "Write Freeze" 구간이 필요하다. 쓰기를 잠시 차단하고, Lag이 0이 되면, 그때 트래픽을 전환한다.

문제는 Write Freeze를 어떻게 구현하느냐였다.

---

## 5. 2단계 Write Freeze 설계

### 5.1 왜 2단계인가?

처음에는 단순히 "WAS를 종료하면 되지 않나?"라고 생각했다. WAS가 종료되면 더 이상 DB에 쓰기 요청이 가지 않으니까.

그러나 이 접근에는 허점이 있었다:

- **배치 작업**: cron이나 스케줄러로 실행되는 배치 작업은 WAS와 독립적으로 DB에 접근할 수 있다.
- **내부 호출**: 다른 서비스나 스크립트가 직접 DB에 접근하는 경우.
- **관리자 작업**: 운영자가 수동으로 쿼리를 실행하는 경우.

WAS 종료만으로는 이런 케이스를 막을 수 없다. 완벽한 정합성을 위해서는 DB 레벨에서의 차단이 필요했다.

### 5.2 Defense in Depth

우리는 "Defense in Depth" 원칙을 적용했다. 단일 방어선에 의존하지 않고, 여러 층위의 보호를 둔다.

**Soft Freeze (Layer 1: Nginx)**
- POST, PUT, DELETE, PATCH 요청을 503으로 반환
- 사용자 경험 보호 (명확한 에러 응답)
- DB 부하 감소

```nginx
map $request_method $write_block {
    default 0;
    POST    1;
    PUT     1;
    DELETE  1;
    PATCH   1;
}

# location 블록 내에서
if ($write_block) { return 503; }
```

**Hard Freeze (Layer 2: MySQL)**
- `SET GLOBAL read_only = ON;`
- 모든 쓰기 시도 차단 (배치, 내부 호출 포함)
- 정합성 100% 보장

Nginx 차단만으로는 Nginx를 거치지 않는 요청을 막을 수 없다. MySQL `read_only`는 "최종 안전장치"로, 어떤 경로로든 쓰기 요청이 들어오면 거부한다.

### 5.3 전환 순서

1. **Soft Freeze ON**: 사용자 쓰기 차단, 명확한 503 응답
2. **Hard Freeze ON**: DB 레벨 쓰기 완전 차단
3. **Lag 0 대기**: 모든 데이터가 RDS에 동기화될 때까지 대기
4. **Nginx 스위칭**: 트래픽을 RDS 연결 WAS(8081)로 전환
5. **Soft Freeze OFF**: RDS로 전환되었으므로 쓰기 허용

이 순서에서 중요한 점은 "Hard Freeze를 Soft Freeze 이후에 건다"는 것이다. 만약 Hard Freeze를 먼저 걸면, 사용자들은 쓰기 요청에 대해 500 에러(서버 오류)를 받게 된다. Soft Freeze가 먼저 동작하면 503(일시적 서비스 불가)이라는 더 명확한 응답을 받는다.

---

## 6. 트러블슈팅: 예상치 못한 문제들

### 6.1 Public IP vs Private IP

Replication 설정 시 처음에 Host MySQL의 Public IP(3.34.162.89)를 사용했다. 설정 자체는 성공한 것처럼 보였지만, Replica 상태는 계속 "Connecting"이었다.

```
Replica_IO_State: Connecting to master
Replica_IO_Running: Connecting
```

원인을 파악하는 데 시간이 걸렸다. RDS는 Private Subnet에 위치하고, NAT Gateway 없이는 인터넷으로 나갈 수 없다. Public IP로의 연결은 불가능했던 것이다.

해결책은 간단했다. Host MySQL의 **Private IP(10.0.1.123)**를 사용하니 즉시 연결되었다. 같은 VPC 내에서는 Private IP로 통신해야 한다는 기본 원칙을 다시 상기하게 된 순간이었다.

### 6.2 인증 플러그인 문제

MySQL 8.0의 기본 인증 플러그인은 `caching_sha2_password`다. 이 플러그인은 SSL 연결을 필수로 요구한다. Replication 설정에서 SSL=0으로 했더니 다음 에러가 발생했다:

```
Authentication plugin 'caching_sha2_password' reported error:
Authentication requires secure connection.
```

선택지는 두 가지였다:
1. SSL 활성화 (보안 강화, 설정 복잡)
2. 인증 플러그인을 `mysql_native_password`로 변경 (설정 단순, 보안 다소 약화)

리허설 환경이고 내부 네트워크 통신이므로, 두 번째 방법을 선택했다:

```sql
ALTER USER 'repl_user'@'%'
  IDENTIFIED WITH mysql_native_password BY 'password';
```

프로덕션에서는 SSL 사용을 권장하지만, 리허설에서는 단순성을 우선했다.

### 6.3 GTID 트랜잭션 충돌

Replication을 시작했더니 SQL 스레드가 멈췄다:

```
Replica_SQL_Running: No
Last_SQL_Error: Worker 1 failed executing transaction
'fdc65049-f838-11f0-8716-024c10e7ffa9:2'
```

GTID `:2`가 실패했다. binlog를 확인해보니 `ALTER USER 'repl_user'` 구문이었다. 덤프 이후 repl_user의 인증 플러그인을 변경한 것이 binlog에 기록되었고, 이것이 RDS로 복제되면서 충돌이 발생한 것이다.

이 경우 해당 트랜잭션을 스킵하는 것이 올바른 해결책이다:

```sql
CALL mysql.rds_skip_repl_error;
```

중요한 것은 "스킵해도 되는지" 판단하는 것이었다. binlog 분석 결과, 스킵되는 트랜잭션은 모두 `ALTER USER` DDL이었고, 애플리케이션 데이터와는 무관했다. 따라서 안전하게 스킵할 수 있었다.

이 경험에서 배운 교훈: **Replication 설정 전에 필요한 사용자 설정을 완료하고, 덤프 이후에는 Host에서 불필요한 쿼리 실행을 자제해야 한다.**

### 6.4 RDS 스펙 변경 후 재발

RDS 인스턴스 클래스를 변경(스펙업)했더니, 동일한 GTID 에러가 재발했다. 스펙 변경으로 RDS가 재시작되면서 Replication이 다시 시작되었고, 이전에 스킵했던 트랜잭션을 다시 시도한 것이다.

이것은 예상하지 못했던 동작이었다. "한 번 스킵하면 영원히 스킵되는 것 아닌가?"라고 생각했는데, 재시작 시에는 다시 시도하는 것으로 보인다.

해결은 동일했다. `rds_skip_repl_error`를 다시 실행했다. 이 경험은 "스펙 변경 후에는 Replication 상태를 반드시 확인해야 한다"는 운영 지침을 남겼다.

---

## 7. 테스트 환경 구축의 중요성

### 7.1 왜 test.billages.com인가?

처음에는 IP 주소로 직접 테스트하려 했다. 그러나 기존 Nginx 설정이 도메인 기반으로 되어 있어 IP 접근이 제대로 라우팅되지 않았다.

여러 시행착오 끝에, 가장 깔끔한 방법은 **별도의 테스트 서브도메인을 만드는 것**이었다. Route53에 A 레코드를 추가하고, Nginx에 별도 server 블록을 구성했다.

```bash
# Route53
test.billages.com → 3.34.162.89

# Nginx
server {
    server_name test.billages.com;
    location /api/ {
        proxy_pass http://backend/;
    }
}
```

이렇게 하면 프로덕션 설정(api.billages.com, www.billages.com)을 건드리지 않고도 안전하게 테스트할 수 있다.

### 7.2 본 마이그레이션과의 차이

리허설에서는 `test.billages.com`으로 테스트하지만, 본 마이그레이션에서는 실제 도메인(api.billages.com)에 영향을 줘야 한다. Cutover 스크립트는 이 차이를 고려하여 작성되어 있다.

---

## 8. 자동화와 휴먼 에러 방지

### 8.1 스크립트화의 이유

수동으로 명령어를 하나씩 입력하면 실수할 가능성이 높다. 특히 긴장되는 마이그레이션 상황에서는 더욱 그렇다. 오타, 순서 착오, 명령어 누락 등이 발생할 수 있다.

그래서 전체 Cutover 과정을 하나의 스크립트(`cutover.sh`)로 통합했다. 스크립트는 다음을 보장한다:

- **순서 보장**: 정해진 순서대로만 실행된다.
- **사전 검증**: 실행 전에 Lag이 0인지, WAS가 정상인지 확인한다.
- **명확한 출력**: 각 단계마다 성공/실패를 표시한다.
- **롤백 기능**: 문제 발생 시 `rollback` 명령으로 원복한다.

### 8.2 확인 프롬프트

스크립트 실행 시 "yes"를 입력해야 진행된다:

```bash
./cutover.sh run
# 정말 실행하시겠습니까? (yes/no): yes
```

이것은 의도치 않은 실행을 방지한다. 실수로 엔터를 눌러도, "yes"를 명시적으로 입력하지 않으면 진행되지 않는다.

### 8.3 상태 확인 기능

`./cutover.sh status`로 현재 상태를 언제든 확인할 수 있다:

```
Backend: localhost:8080
Replication Lag: 0초
Host read_only: 0
Soft Freeze: OFF
```

마이그레이션 전후로 상태를 비교하면, 무엇이 변경되었는지 명확히 알 수 있다.

---

## 9. 롤백 전략

### 9.1 롤백이 필요한 상황

모든 마이그레이션에는 "실패 시 어떻게 할 것인가?"라는 계획이 필요하다. 우리가 정의한 롤백 기준은:

- 전환 후 5xx 에러율 > 1%
- 주요 API 응답시간 p95 > 2초
- 데이터 불일치 감지

### 9.2 PNR (Point of No Return)

마이그레이션에는 "되돌릴 수 없는 지점"이 있다. Replication을 중단하고 RDS에 직접 쓰기가 시작되면, Host MySQL과 RDS의 데이터가 분기된다. 이 시점이 PNR이다.

PNR 이전: Nginx만 8080으로 되돌리면 원복 가능.
PNR 이후: 데이터 차이가 발생하므로, 단순 원복이 불가능. 데이터 동기화가 필요.

우리 전략은 PNR 이후에도 Host MySQL을 2주간 유지하는 것이다. 이 기간 동안 문제가 발생하면, 수동으로 데이터를 동기화하고 원복할 수 있다.

### 9.3 롤백 스크립트

```bash
./cutover.sh rollback
```

이 명령은:
1. Nginx를 8080으로 되돌린다.
2. Soft Freeze를 해제한다.
3. Host MySQL의 read_only를 해제한다.

30초 이내에 원복이 완료된다.

---

## 10. 배운 것들

### 10.1 기술적 교훈

1. **문서만 읽지 말고 실험하라**: RDS gtid_mode 설정 불가 에러를 만났을 때, 포기하지 않고 실제 동작을 테스트해보니 해결책을 찾았다.

2. **네트워크 기본기**: Private Subnet의 RDS는 Public IP로 연결할 수 없다. VPC 내부 통신은 Private IP를 사용해야 한다.

3. **Defense in Depth**: 단일 방어선에 의존하지 않는다. Nginx 차단과 MySQL read_only를 함께 사용하여 정합성을 보장한다.

4. **스크립트화**: 수동 작업은 실수를 유발한다. 가능한 모든 것을 자동화한다.

### 10.2 운영적 교훈

1. **리허설의 중요성**: 본 마이그레이션 전에 리허설을 수행하여 예상치 못한 문제들을 미리 발견했다.

2. **롤백 계획**: 모든 변경에는 롤백 계획이 있어야 한다. "실패하면 어떻게 하지?"라는 질문에 답할 수 있어야 한다.

3. **문서화**: 지금 당장은 기억하고 있지만, 몇 달 후에는 잊어버린다. 상세한 문서화가 미래의 나(또는 동료)를 돕는다.

---

## 11. 결론

이 마이그레이션 프로젝트는 단순한 "DB 옮기기"가 아니었다. 서비스 연속성을 유지하면서, 데이터 정합성을 보장하고, 실패 시 빠르게 복구할 수 있는 체계를 구축하는 것이었다.

MySQL Replication, GTID, 2단계 Write Freeze, 자동화 스크립트 등 여러 기술 요소를 조합하여 "초 단위 무중단 전환"이라는 목표에 다가갔다.

물론 아직 리허설 단계이고, 본 마이그레이션은 남아 있다. 그러나 이 과정에서 쌓은 경험과 문서는 본 마이그레이션을 자신 있게 수행할 수 있는 기반이 되었다.

---

## 부록: 핵심 명령어 요약

```bash
# Replication 상태 확인
mysql -h RDS_ENDPOINT -u admin -p -e "SHOW REPLICA STATUS\G"

# Cutover 실행
./cutover.sh run

# 롤백
./cutover.sh rollback

# 상태 확인
./cutover.sh status

# 헬스체크
curl http://test.billages.com/api/actuator/health
```

---

## 관련 문서

- 작업 로그: `docs/report/DB_MIGRATION_FULL_WORK_LOG.md`
- 트러블슈팅: `docs/troubleshooting/DB_MIGRATION_TROUBLESHOOTING.md`
- 실행 런북: `context/migration/db-migration-runbook.md`