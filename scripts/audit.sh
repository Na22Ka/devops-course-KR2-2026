#!/usr/bin/env bash
set -uo pipefail
export LC_ALL=C
PASS=0; FAIL=0
check() {
    local desc="$1" expected="$2" actual="$3"
    if [[ "$actual" == "$expected" ]]; then
        echo "  [OK]   $desc"; ((PASS++))
    else
        echo "  [FAIL] $desc (ожидалось: '$expected', получено: '$actual')"; ((FAIL++))
    fi
}
sudo -v || exit 1
sshd_config=$(sudo sshd -T) || exit 1
ufw_status=$(sudo ufw status verbose) || exit 1
echo "Аудит конфигурации: $(hostname -f), $(date '+%Y-%m-%d %H:%M')"
echo "[1] Служба SSH"
check "Вход от имени root запрещён" no "$(awk '$1=="permitrootlogin" {print $2}' <<< "$sshd_config")"
check "Парольная аутентификация отключена" no "$(awk '$1=="passwordauthentication" {print $2}' <<< "$sshd_config")"
ports=$(awk '$1=="port" {print $2}' <<< "$sshd_config")
nonstandard=yes
if [[ -z "$ports" ]] || grep -qx 22 <<< "$ports"; then nonstandard=no; fi
check "Все порты SSH отличаются от 22" yes "$nonstandard"
check "MaxAuthTries равно 3" 3 "$(awk '$1=="maxauthtries" {print $2}' <<< "$sshd_config")"
echo "[2] Межсетевой экран"
check "Межсетевой экран активен" active "$(awk '/^Status:/ {print $2}' <<< "$ufw_status")"
check "Входящий трафик по умолчанию запрещён" deny "$(sed -n 's/^Default: \([^ ]*\) (incoming).*/\1/p' <<< "$ufw_status")"
echo "[3] Учётные записи"
awk -F: '$3>=1000 && $3<65534 {printf "    %s (uid=%s)\n",$1,$3}' /etc/passwd
echo "[4] Веб-сервер"
check "Служба nginx активна" active "$(systemctl is-active nginx)"
nginx_valid=no
sudo nginx -t >/dev/null 2>&1 && nginx_valid=yes
check "Конфигурация nginx корректна" yes "$nginx_valid"
cert_valid=no
cert_check_seconds="${CERT_CHECK_SECONDS:-2592000}"
if [[ "$cert_check_seconds" =~ ^[0-9]+$ ]] &&
    openssl x509 -in /etc/ssl/certs/devops.crt -noout -checkend "$cert_check_seconds" >/dev/null 2>&1; then
    cert_valid=yes
fi
check "Сертификат действует не менее заданного порога (по умолчанию 30 дней)" yes "$cert_valid"
permissions_valid=no
if writable=$(sudo find /var/www/devops-site -perm -o+w 2>/dev/null) &&
    key_mode=$(sudo stat -c '%a' /etc/ssl/private/devops.key 2>/dev/null) &&
    [[ -z "$writable" && "$key_mode" == 600 ]]; then
    permissions_valid=yes
fi
check "Нет записи для всех; права закрытого ключа 600" yes "$permissions_valid"
echo "[5] Контейнеризация"
check "Служба docker активна" active "$(systemctl is-active docker)"
db_health=$(docker inspect -f '{{.State.Health.Status}}' app-db-1 2>/dev/null || true)
check "Контейнер PostgreSQL healthy" healthy "$db_health"
bindings_safe=no
if listeners=$(ss -H -ltn); then
    bindings_safe=$(awk '
        $4 ~ /:(5000|5432)$/ && $4 !~ /^127[.]0[.]0[.]1:/ {bad=1}
        END {print (bad ? "no" : "yes")}
    ' <<< "$listeners")
fi
check "Порты 5000 и 5432 доступны только через 127.0.0.1 либо не опубликованы" yes "$bindings_safe"
app_env_file="${APP_ENV_FILE:-/home/devops/app/.env}"
env_mode=$(sudo stat -c '%a' "$app_env_file" 2>/dev/null || true)
check "Файл окружения приложения имеет права 600" 600 "$env_mode"
echo "Пройдено: $PASS, не пройдено: $FAIL"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
