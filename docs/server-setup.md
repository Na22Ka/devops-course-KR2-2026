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

## 8. Локальное имя

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

## 9. Восстановление после 01-clean-install

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

## 10. Наблюдения

При включении UFW прекратилась старая резервная SSH-сессия на прежнем
гостевом порту 22; новые соединения на 2222 работают. В журнале UFW есть
пакеты старой сессии с DPT=22. Управляющая сессия переоткрыта на порту 2222.
Проверка закрытого порта 8080 дала таймаут curl (код 28) и UFW BLOCK:
SRC=192.168.56.1, DST=192.168.56.101, PROTO=TCP, DPT=8080.
