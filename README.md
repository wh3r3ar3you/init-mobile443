# init-mobile443

🚀 Bootstrap для VPN-ноды на Debian/Ubuntu с фильтрацией доступа к выбранным портам только из мобильных ASN и с предварительным отсевом Traffic Guard списков.

Проект основан на логике `vpn-bootstrap`, но общий Traffic Guard `blacklist` заменен на `mobile443`-фильтр:

- 🛡️ `traf_guard_government` и `traf_guard_antiscanner` дропают адреса из Traffic Guard списков.
- 📱 `allowed_mobile_443` пропускает только префиксы заданных мобильных ASN.
- 🔒 остальные источники на фильтруемых портах логируются и дропаются.

Telegram/Remnawave уведомлений и мониторинга в этой сборке нет.

## ✨ Что делает bootstrap

Скрипт выполняет базовую подготовку сервера:

- обновляет систему;
- настраивает hostname;
- усиливает SSH;
- ставит Docker, Zsh и Speedtest CLI;
- применяет sysctl-тюнинг;
- опционально включает VPN defense profile;
- опционально ставит XanMod LTS kernel;
- разворачивает `mobile443` firewall, `ipset` и systemd timer.

## 📦 Состав проекта

- `bootstrap.sh` - основной интерактивный bootstrap.
- `install.sh` - one-line installer с GitHub.
- `scripts/mobile443-common.sh` - общие функции для `ipset` и `iptables`.
- `scripts/mobile443-update.sh` - скачивание Traffic Guard списков и RIPEstat prefixes для ASN allowlist.
- `scripts/mobile443-apply-cache.sh` - восстановление `ipset` и firewall rules из локального кэша.
- `scripts/mobile443-apply-exceptions.sh` - загрузка исключений в отдельный `ipset`.
- `systemd/mobile443-update.service` - разовое обновление списков.
- `systemd/mobile443-update.timer` - ежедневный запуск обновления.
- `systemd/mobile443-apply.service` - применение кэша после старта системы.

## ⚡ Быстрый старт

One-line install:

```bash
apt install curl -y && bash <(curl -fsSL https://raw.githubusercontent.com/wh3r3ar3you/init-mobile443/main/install.sh)
```

Или запуск из клонированного репозитория:

```bash
chmod +x bootstrap.sh
./bootstrap.sh
```

Установщик интерактивно спросит, какие порты фильтровать:

```text
Enter mobile443 filtered ports [443]:
```

Можно ввести один порт или список через пробелы/запятые:

```text
443
443 8443
443,8443
```

Переменная окружения `MOBILE443_PORTS` используется только как дефолт для этого вопроса:

```bash
MOBILE443_PORTS="443 8443" ./bootstrap.sh
```

## 🧩 Что спросит установщик

Во время запуска `bootstrap.sh` запросит:

- hostname;
- SSH port;
- порты, которые должен фильтровать `mobile443`;
- публичный SSH key для `/root/.ssh/authorized_keys`;
- включать ли VPN defense profile;
- добавить ли source IP/CIDR исключения для `mobile443`;
- ставить ли XanMod LTS kernel;
- делать ли автоматический reboot после установки XanMod.

## 🔥 Firewall logic

Bootstrap применяет базовые правила:

- `conntrack INVALID` drop для `INPUT` и `FORWARD`;
- `ICMP echo-request` drop;
- `TCPMSS --clamp-mss-to-pmtu` для `mangle/FORWARD`;
- `DOCKER-USER` защиту от invalid forwarded-трафика, если цепочка существует;
- опциональные `VPN_SYN_LIM` и `VPN_UDP_AMP`, если включен VPN defense profile.

Дополнительно `mobile443` создает:

- `ipset traf_guard_government`;
- `ipset traf_guard_antiscanner`;
- `ipset allowed_mobile_443`;
- `ipset mobile443_exceptions`;
- chain `TRAF_GUARD_PRECHECK`;
- chain `FILTER_MOBILE_443`.

Порядок обработки трафика:

```text
INPUT/FORWARD/DOCKER-USER tcp,udp dport <PORTS> -> FILTER_MOBILE_443
FILTER_MOBILE_443: mobile443_exceptions -> ACCEPT
FILTER_MOBILE_443 -> TRAF_GUARD_PRECHECK
TRAF_GUARD_PRECHECK: traf_guard_government -> LOG + DROP
TRAF_GUARD_PRECHECK: traf_guard_antiscanner -> LOG + DROP
FILTER_MOBILE_443: allowed_mobile_443 -> ACCEPT
FILTER_MOBILE_443: non-mobile -> LOG + DROP
```

## 📱 ASN allowlist

Список ASN хранится здесь:

```text
/opt/mobile443/asns.conf
```

Если файл уже существует, bootstrap его не перезаписывает. Можно отредактировать список вручную и запустить обновление:

```bash
/usr/local/sbin/mobile443-update.sh
```

Префиксы ASN скачиваются через RIPEstat `announced-prefixes`.

## ✅ Исключения

Во время bootstrap можно добавить source IP или CIDR, которые должны проходить фильтр до Traffic Guard и mobile ASN проверки.

Поддерживаются одиночные IPv4-адреса и IPv4 CIDR:

```text
203.0.113.10
203.0.113.0/24
10.0.0.0/8
```

Исключения хранятся здесь:

```text
/opt/mobile443/exceptions.conf
```

После обновления списков автоматически запускается:

```bash
/usr/local/sbin/mobile443-apply-exceptions.sh
```

Скрипт нормализует одиночные IP в `/32`, пропускает невалидные строки и загружает результат в `ipset mobile443_exceptions`.

## 🛡️ Traffic Guard списки

Используются публичные списки:

```text
https://raw.githubusercontent.com/shadow-netlab/traffic-guard-lists/refs/heads/main/public/government_networks.list
https://raw.githubusercontent.com/shadow-netlab/traffic-guard-lists/refs/heads/main/public/antiscanner.list
```

Локальные копии:

```text
/opt/mobile443/lists/government_networks.list
/opt/mobile443/lists/antiscanner.list
```

## ⚙️ Конфигурация

Основной файл:

```text
/opt/mobile443/config.conf
```

Дефолтные значения:

```bash
PORTS="443"
ENABLE_TRAF_GUARD="true"
ENABLE_TRAF_GUARD_GOVERNMENT="true"
ENABLE_TRAF_GUARD_ANTISCANNER="true"
ENABLE_MOBILE_ALLOW="true"
TRAF_GUARD_BASE_URL="https://raw.githubusercontent.com/shadow-netlab/traffic-guard-lists/refs/heads/main/public"
```

## 🔎 Проверка

Systemd:

```bash
systemctl status mobile443-update.timer --no-pager
systemctl status mobile443-update.service --no-pager
systemctl status mobile443-apply.service --no-pager
```

Firewall chains:

```bash
iptables -L TRAF_GUARD_PRECHECK -n -v --line-numbers
iptables -L FILTER_MOBILE_443 -n -v --line-numbers
```

IP sets:

```bash
ipset list traf_guard_government | head -20
ipset list traf_guard_antiscanner | head -20
ipset list allowed_mobile_443 | head -20
ipset list mobile443_exceptions | head -20
```

## ⚠️ Важно

Проект меняет SSH, firewall и sysctl. Запускайте bootstrap только на сервере, где есть аварийный доступ на случай rollback.
