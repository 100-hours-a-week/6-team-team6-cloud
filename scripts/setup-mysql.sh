#!/bin/bash
# Billage MySQL Setup Script
# 외부 접속 가능한 MySQL 사용자 설정

set -e

echo "=========================================="
echo "Billage MySQL Setup"
echo "=========================================="
echo ""

# 변수 입력 받기
read -p "DB 사용자명 (기본: billage): " DB_USER
DB_USER=${DB_USER:-billage}

read -p "DB 이름 (기본: billage): " DB_NAME
DB_NAME=${DB_NAME:-billage}

read -sp "DB 비밀번호: " DB_PASSWORD
echo ""

if [ -z "$DB_PASSWORD" ]; then
    echo "Error: 비밀번호를 입력해주세요."
    exit 1
fi

read -sp "DB 비밀번호 확인: " DB_PASSWORD_CONFIRM
echo ""

if [ "$DB_PASSWORD" != "$DB_PASSWORD_CONFIRM" ]; then
    echo "Error: 비밀번호가 일치하지 않습니다."
    exit 1
fi

echo ""
echo "=========================================="
echo "설정 정보 확인"
echo "=========================================="
echo "  DB 사용자명: $DB_USER"
echo "  DB 이름: $DB_NAME"
echo "  접속 허용: 모든 IP (외부 접속 가능)"
echo ""

read -p "위 설정으로 진행하시겠습니까? (y/N): " CONFIRM
if [ "$CONFIRM" != "y" ] && [ "$CONFIRM" != "Y" ]; then
    echo "취소되었습니다."
    exit 0
fi

echo ""
echo "[1/4] MySQL 보안 설정 확인..."

# root 비밀번호가 설정되어 있는지 확인
if sudo mysql -e "SELECT 1" 2>/dev/null; then
    echo "  - root 인증: auth_socket (sudo 사용)"
    MYSQL_CMD="sudo mysql"
else
    echo "  - root 인증: 비밀번호 필요"
    read -sp "MySQL root 비밀번호: " MYSQL_ROOT_PASSWORD
    echo ""
    MYSQL_CMD="mysql -u root -p$MYSQL_ROOT_PASSWORD"
fi

echo ""
echo "[2/4] 데이터베이스 생성..."
$MYSQL_CMD -e "CREATE DATABASE IF NOT EXISTS \`$DB_NAME\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
echo "  - 데이터베이스 '$DB_NAME' 생성 완료"

echo ""
echo "[3/4] 사용자 생성 및 권한 부여..."
# 기존 사용자 삭제 (있으면)
$MYSQL_CMD -e "DROP USER IF EXISTS '$DB_USER'@'%';"
$MYSQL_CMD -e "DROP USER IF EXISTS '$DB_USER'@'localhost';"

# 새 사용자 생성 (외부 + 로컬)
$MYSQL_CMD -e "CREATE USER '$DB_USER'@'%' IDENTIFIED BY '$DB_PASSWORD';"
$MYSQL_CMD -e "CREATE USER '$DB_USER'@'localhost' IDENTIFIED BY '$DB_PASSWORD';"

# 권한 부여
$MYSQL_CMD -e "GRANT ALL PRIVILEGES ON \`$DB_NAME\`.* TO '$DB_USER'@'%';"
$MYSQL_CMD -e "GRANT ALL PRIVILEGES ON \`$DB_NAME\`.* TO '$DB_USER'@'localhost';"
$MYSQL_CMD -e "FLUSH PRIVILEGES;"

echo "  - 사용자 '$DB_USER' 생성 완료"
echo "  - 권한 부여 완료"

echo ""
echo "[4/4] 외부 접속 허용 설정..."

# MySQL 설정 파일 수정
MYSQL_CONF="/etc/mysql/mysql.conf.d/mysqld.cnf"

if grep -q "^bind-address" $MYSQL_CONF; then
    sudo sed -i 's/^bind-address.*/bind-address = 0.0.0.0/' $MYSQL_CONF
    echo "  - bind-address 변경 완료"
else
    echo "bind-address = 0.0.0.0" | sudo tee -a $MYSQL_CONF > /dev/null
    echo "  - bind-address 추가 완료"
fi

# MySQL 재시작
echo "  - MySQL 재시작 중..."
sudo systemctl restart mysql

echo ""
echo "=========================================="
echo "MySQL 설정 완료!"
echo "=========================================="
echo ""
echo "접속 정보:"
echo "  Host: $(curl -s ifconfig.me 2>/dev/null || echo '<서버 IP>')"
echo "  Port: 3306"
echo "  Database: $DB_NAME"
echo "  Username: $DB_USER"
echo "  Password: (입력한 비밀번호)"
echo ""
echo "테스트 명령어:"
echo "  mysql -h <서버IP> -u $DB_USER -p $DB_NAME"
echo ""
echo "Spring Boot application.yml 예시:"
echo "  spring:"
echo "    datasource:"
echo "      url: jdbc:mysql://<서버IP>:3306/$DB_NAME?useSSL=false&serverTimezone=Asia/Seoul"
echo "      username: $DB_USER"
echo "      password: <비밀번호>"
echo ""