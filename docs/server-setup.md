# Конфигурация виртуальной машины devops-vm

## 1. Параметры машины

VirtualBox 7.1.8. Ubuntu Server 24.04 LTS, стандартная установка без GUI.
Установочный образ 24.04.4; после обновления система сообщает 24.04.5 LTS.
Память 2048 МБ, 2 ядра, динамический диск VDI 25 ГБ.
Установка на весь виртуальный диск с LVM.

## 2. Сетевые интерфейсы

| Интерфейс | Адаптер | Адрес | Назначение |
|---|---|---|---|
| enp0s3 | NAT | 10.0.2.15/24 | Доступ в Интернет |
| enp0s8 | Host-only | 192.168.56.101/24 | Доступ с ноутбука |

Адреса получаются по DHCP. Host-only интерфейс ноутбука: 192.168.56.1/24.
После восстановления или смены сети проверять `ip -brief address`.

## 3. Правило проброса портов

Имя `ssh`, TCP, адрес хоста 127.0.0.1, порт хоста 2222, адрес гостя пустой.
При чистой установке порт гостя 22, после hardening — 2222.

## 4. Учётные записи

- `student`, UID 1000: первоначальная учётная запись с sudo, вход через консоль VM.
- `devops`, UID 1001: группы devops, sudo, users; SSH по отдельному ключу ED25519.

Пароли задаются владельцем вручную. Секреты в документе не фиксируются.
Закрытый ключ на ноутбуке: `~/.ssh/devops_vm`. На сервер переносится только
`devops_vm.pub`, в `/home/devops/.ssh/authorized_keys`.
Владелец каталога и файла devops:devops, права 700 и 600 соответственно.

Профиль в Windows `~/.ssh/config`:

```sshconfig
Host devops
    HostName 127.0.0.1
    Port 2222
    User devops
    IdentityFile ~/.ssh/devops_vm
    IdentitiesOnly yes

Host devops.local
    HostName devops.local
    Port 2222
    User devops
    IdentityFile ~/.ssh/devops_vm
    IdentitiesOnly yes
```

Ключ хоста сверяется с выводом в консоли VM:
`sudo ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub`.
Проверенный отпечаток установленной машины:
`SHA256:vwl98oMsAvyCzWRv1LNa5OHQE/Se7aKnKqsvxQ6dTP8`.

## 5. Служба SSH

Основной файл `/etc/ssh/sshd_config` не изменён, копия — `.backup`.
Настройки размещены в `/etc/ssh/sshd_config.d/99-hardening.conf`:

```text
Port 2222
PermitRootLogin no
PasswordAuthentication no
PubkeyAuthentication yes
PermitEmptyPasswords no
MaxAuthTries 3
LoginGraceTime 30
AllowUsers devops
X11Forwarding no
ClientAliveInterval 300
ClientAliveCountMax 2
```

В `50-cloud-init.conf` закомментирована строка `PasswordAuthentication yes`,
иначе она имеет приоритет перед файлом 99. Копия — `50-cloud-init.conf.backup`.
`ssh.socket` отключён, `ssh.service` включён. Проверки: `sudo sshd -t`,
`sudo sshd -T`, `sudo ss -tlnp | grep sshd`.

## 6. Правила межсетевого экрана

UFW активен и включён в автозапуск. Политики: deny incoming, allow outgoing,
disabled routed. Для IPv4 и IPv6 разрешены 80/tcp, 443/tcp и LIMIT для 2222/tcp.
Журналирование medium, журнал `/var/log/ufw.log`.

## 7. Снимки состояния

| Снимок | Момент создания |
|---|---|
| 01-clean-install | После установки и обновления, до создания devops и ключей; VM выключена |
| 02-keys-configured | После создания devops, настройки ключей и проверки SSH |
| 03-ssh-hardened | После hardening и проверок входа, до UFW и локального имени |

## 8. Веб-сервер

Установлены пакеты `nginx` (1.24.0 в Ubuntu 24.04) и `rsync` (3.2.7):

```bash
sudo apt update && sudo apt install -y nginx rsync
sudo systemctl enable --now nginx
```

Конфигурация: `/etc/nginx/sites-available/devops-site`; включение — ссылка
`/etc/nginx/sites-enabled/devops-site` на этот файл. Ссылка `default` удалена,
исходная стандартная конфигурация сохранена. Каталог `/var/www/devops-site`
принадлежит `devops:devops`, права каталога 755, файлов 644. Рабочие процессы
`www-data` читают файлы, но не могут создавать или изменять их.

Публичный сертификат: `/etc/ssl/certs/devops.crt`, root:root, 644.
Закрытый ключ: `/etc/ssl/private/devops.key`, root:root, 600; не переносится
на хост и не включается в Git. Самоподписанный RSA-2048 сертификат выдан
на 365 дней, SAN `DNS:devops.local`, с 06.11.2026 до 06.11.2027:

```bash
sudo openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout /etc/ssl/private/devops.key \
  -out /etc/ssl/certs/devops.crt \
  -subj '/CN=devops.local' -addext 'subjectAltName=DNS:devops.local'
sudo chown root:root /etc/ssl/private/devops.key /etc/ssl/certs/devops.crt
sudo chmod 600 /etc/ssl/private/devops.key
sudo chmod 644 /etc/ssl/certs/devops.crt
```

Содержимое конфигурации:

```nginx
server {
    listen 80;
    listen [::]:80;
    server_name devops.local;
    return 301 https://$host$request_uri;
}
server {
    listen 443 ssl;
    listen [::]:443 ssl;
    server_name devops.local;
    root /var/www/devops-site;
    index index.html;
    ssl_certificate /etc/ssl/certs/devops.crt;
    ssl_certificate_key /etc/ssl/private/devops.key;
    ssl_protocols TLSv1.2 TLSv1.3;
    location / {
        try_files $uri $uri/ =404;
    }
    error_page 404 /404.html;
    access_log /var/log/nginx/devops-site.access.log;
    error_log /var/log/nginx/devops-site.error.log;
}
```

После каждого изменения: `sudo nginx -t && sudo systemctl reload nginx`.
Порты 80/443 разрешены существующими правилами UFW, дубли профилей Nginx
не добавляются. HTTP возвращает 301, HTTPS — 200; неизвестный путь — 404
со страницей `404.html`. HSTS не включён для учебного самоподписанного TLS.
Логи: `/var/log/nginx/devops-site.access.log` и `devops-site.error.log`.

На Windows создан отдельный WSL1 `DevOpsHost` (Ubuntu 24.04). В Linux-home
пользователя student хранятся SSH-профиль и ключ с правами 600, каталог 700.
Для общей рабочей копии на `/mnt/c` Git настроен с `core.autocrlf=true`,
а `.gitattributes` задаёт LF для shell, Markdown и HTML. Это исключает ложное
сообщение о незакоммиченных изменениях из-за разных переносов строк.
Публичный сертификат получен через ранее проверенный SSH:

```bash
scp devops:/etc/ssl/certs/devops.crt ~/devops.crt
curl --cacert ~/devops.crt -I https://devops.local
```

Доставка из чистого репозитория: `bash scripts/deploy.sh --dry-run`, затем
`bash scripts/deploy.sh`. Скрипт передаёт только `site/` с `--delete` и
`--chmod=D755,F644`, требует index.html, отвергает изменения (включая staged),
открывает один SSH для rsync с BatchMode и ConnectTimeout, проверяет HTTPS
с `--cacert` и сообщает хеш коммита. Работает из любого подкаталога.

Аудит: `bash scripts/audit.sh`. По умолчанию порог сертификата 2592000 секунд
(30 дней); для отрицательного теста используется
`CERT_CHECK_SECONDS=34560000 bash scripts/audit.sh` (400 дней).
Второй отрицательный тест — временные права 666 на index.html; после него
обязательно восстановить 644 и повторить аудит.

Снимок `04-nginx-https` создан после настройки TLS, до первой доставки сайта.
Снимок `pre-practice-06` сохраняет завершённую практическую 5 до отката.

## 9. Локальное имя

В Windows `C:\Windows\System32\drivers\etc\hosts` добавлено:

```text
192.168.56.101 devops.local
```

В Ubuntu: hostname `devops-vm`, строка `/etc/hosts`:

```text
127.0.1.1 devops-vm.devops.local devops-vm
```

`hostname -f` возвращает `devops-vm.devops.local`. Это локальное соответствие
в hosts, публичные DNS-записи не создавались.

## 10. Восстановление после 01-clean-install

Откат меняет состояние диска VM, но не настройки SSH-клиента Windows. После
отката проверить проброс: гостевой SSH использует порт 22, порт хоста — 2222.
Настройки сети проверить в VirtualBox. Команды ниже выполняются в консоли
Ubuntu под student; действующие SSH-сессии сохранять до проверки нового входа.

1. Создать учётную запись и включить sudo:

```bash
sudo adduser devops
sudo usermod -aG sudo devops
```

2. Установить открытый ключ с Windows PowerShell:

```powershell
Get-Content "$env:USERPROFILE\.ssh\devops_vm.pub" | ssh -p 2222 devops@127.0.0.1 "mkdir -p ~/.ssh && chmod 700 ~/.ssh && cat >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys"
ssh devops
```

3. В консоли Ubuntu сохранить копии, закомментировать конфликт cloud-init,
создать файл 99-hardening.conf с точным содержимым из раздела 5:

```bash
sudo cp /etc/ssh/sshd_config /etc/ssh/sshd_config.backup
sudo cp /etc/ssh/sshd_config.d/50-cloud-init.conf /etc/ssh/sshd_config.d/50-cloud-init.conf.backup
sudo sed -i 's/^PasswordAuthentication yes/# PasswordAuthentication yes/' /etc/ssh/sshd_config.d/50-cloud-init.conf
sudo nano /etc/ssh/sshd_config.d/99-hardening.conf
sudo sshd -t
sudo sshd -T | grep -E '^(port|permitrootlogin|passwordauthentication|maxauthtries|allowusers) '
sudo systemctl disable --now ssh.socket
sudo systemctl enable --now ssh.service
sudo systemctl restart ssh
sudo ss -tlnp | grep sshd
```

4. Изменить порт гостя в пробросе VirtualBox на 2222. В новом PowerShell
проверить `ssh devops`, а также ожидаемый отказ для `ssh -o User=root devops`
и `ssh -o PubkeyAuthentication=no devops`.

5. Настроить UFW. Разрешающее правило создаётся до включения:

```bash
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow 2222/tcp comment 'SSH'
sudo ufw allow 80/tcp comment 'HTTP'
sudo ufw allow 443/tcp comment 'HTTPS'
sudo ufw enable
# Проверить новое SSH-соединение перед продолжением.
sudo ufw delete allow 2222/tcp
sudo ufw limit 2222/tcp comment 'SSH rate-limited'
sudo ufw logging medium
sudo ufw status verbose
```

6. Восстановить имя сервера:

```bash
sudo hostnamectl set-hostname devops-vm
sudo sed -i 's/^127.0.1.1.*/127.0.1.1 devops-vm.devops.local devops-vm/' /etc/hosts
hostname -f
```

Запись hosts и профиль devops.local в Windows сохраняются при откате VM.
Если адрес Host-only изменился, обновить запись hosts. Проверить с ноутбука
`ping devops.local` и `ssh devops.local`.

7. Скопировать скрипт из репозитория и выполнить `bash scripts/audit.sh`.
Проверка успешна при шести OK и коде 0. Для проверки ошибки временно изменить
MaxAuthTries в 99-hardening.conf на 10: аудит должен дать один FAIL и код 1.
Перезапуск SSH для чтения конфигурации через sshd -T не требуется. После
проверки обязательно вернуть MaxAuthTries 3 и проверить `sudo sshd -t`.

## 11. Наблюдения

При включении UFW прекратилась старая резервная SSH-сессия на прежнем
гостевом порту 22; новые соединения на 2222 работают. В журнале UFW есть
пакеты старой сессии с DPT=22. Управляющая сессия переоткрыта на порту 2222.
Проверка закрытого порта 8080 дала таймаут curl (код 28) и UFW BLOCK:
SRC=192.168.56.1, DST=192.168.56.101, PROTO=TCP, DPT=8080.

## 12. Результаты проверки аудита

Проверка выполнена на установленной виртуальной машине:

| Конфигурация | Успешные проверки | Ошибки | Код завершения |
|---|---|---|---|
| Корректная, MaxAuthTries 3 | 6 | 0 | 0 |
| Намеренная ошибка, MaxAuthTries 10 | 5 | 1 | 1 |
| После восстановления MaxAuthTries 3 | 6 | 0 | 0 |

Во втором запуске получено сообщение `[FAIL] MaxAuthTries равно 3`
с ожидаемым значением 3 и фактическим 10. Перед тестом сохранена точная копия
файла 99-hardening.conf; обработчик EXIT обеспечивал восстановление при ошибке.
После отрицательной проверки исходный файл восстановлен, `sshd -t` завершился
успешно, эффективное значение MaxAuthTries снова 3. Повторный аудит прошёл.
Служба SSH во время отрицательного теста не перезапускалась.

## 13. Проверка восстановления в практической 6

Откат выполнен к 01-clean-install. Настройки восстановлены по этому документу;
пароли student/devops вводились владельцем вручную. После отката дополнительно
потребовались DHCP для enp0s8 и каталог `/run/sshd` перед `sshd -t`:

```yaml
# /etc/netplan/60-host-only.yaml, владелец root, права 600
network:
  version: 2
  ethernets:
    enp0s8:
      dhcp4: true
      optional: true
```

Применить `sudo netplan apply`; при отсутствующем `/run/sshd` выполнить
`sudo install -d -m 755 /run/sshd`. После восстановления порт гостя в пробросе
VirtualBox снова 2222. Проверены SSH по ключу, FQDN, адреса интерфейсов и
6 успешных проверок исходного аудита (код 0). Полное время с ожиданием
ручного ввода паролей не укладывалось в учебные 10 минут; 6 секунд в выводе
обозначают только повторное автоматическое применение настроек.
