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
echo "Пройдено: $PASS, не пройдено: $FAIL"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
