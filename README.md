# init-vpn-node mobile443

Первичная конфигурация VPN-ноды на Debian/Ubuntu на базе `vpn-bootstrap`, но с firewall-фильтром из `mobile443-filter`.

Скрипт делает всё базовое из `vpn-bootstrap`: обновление системы, SSH hardening, Docker, Zsh, Speedtest CLI, sysctl-тюнинг, опциональный VPN defense profile и опциональную установку XanMod LTS. Старый общий Traffic Guard `blacklist` из `vpn-bootstrap` заменён на `mobile443`-логику:

1. `traf_guard_government` и `traf_guard_antiscanner` дропают IP из Traffic Guard списков.
2. `allowed_mobile_443` пропускает только префиксы из заданных мобильных ASN.
3. Остальные источники на фильтруемых портах логируются и дропаются.

Telegram/Remnawave уведомлений и мониторинга в этой сборке нет.

## Что устанавливается

- `bootstrap.sh` — основной интерактивный bootstrap.
- `install.sh` — one-line installer с GitHub.
- `scripts/mobile443-common.sh` — общие функции для `ipset`/`iptables`.
- `scripts/mobile443-update.sh` — скачивает Traffic Guard списки и RIPEstat prefixes для ASN allowlist.
- `scripts/mobile443-apply-cache.sh` — восстанавливает `ipset` и firewall rules из локального кэша.
- `scripts/mobile443-apply-exceptions.sh` — загружает исключения в отдельный `ipset`.
- `systemd/mobile443-update.service` и `systemd/mobile443-update.timer` — ежедневное обновление.
- `systemd/mobile443-apply.service` — применение кэша после старта.

## Запуск

```bash
apt install curl -y && bash <(curl -fsSL https://raw.githubusercontent.com/wh3r3ar3you/mobile443upd/main/install.sh)
```

Или из клонированного репозитория:

```bash
chmod +x bootstrap.sh
./bootstrap.sh
```

По умолчанию фильтруется порт `443`. Можно передать список портов через переменную окружения:

```bash
MOBILE443_PORTS="443 8443" ./bootstrap.sh
```

## Что спрашивает bootstrap

- hostname;
- SSH port;
- публичный SSH key для `/root/.ssh/authorized_keys`;
- включать ли VPN defense profile;
- добавить ли source IP/CIDR исключения для `mobile443`;
- ставить ли XanMod LTS kernel;
- делать ли автоматический reboot после установки XanMod.

## Firewall

Bootstrap ставит общие правила из первого проекта:

- `conntrack INVALID` drop для `INPUT` и `FORWARD`;
- `ICMP echo-request` drop;
- `TCPMSS --clamp-mss-to-pmtu` для `mangle/FORWARD`;
- `DOCKER-USER` защиту от invalid forwarded-трафика, если цепочка есть;
- опциональные `VPN_SYN_LIM` и `VPN_UDP_AMP`, если включён VPN defense profile.

Отдельно `mobile443` создаёт:

- `ipset traf_guard_government`;
- `ipset traf_guard_antiscanner`;
- `ipset allowed_mobile_443`;
- `ipset mobile443_exceptions`;
- chain `TRAF_GUARD_PRECHECK`;
- chain `FILTER_MOBILE_443`.

Порядок обработки:

```text
INPUT/FORWARD/DOCKER-USER tcp,udp dport <PORTS> -> FILTER_MOBILE_443
FILTER_MOBILE_443: mobile443_exceptions -> ACCEPT
FILTER_MOBILE_443 -> TRAF_GUARD_PRECHECK
TRAF_GUARD_PRECHECK: traf_guard_government -> LOG + DROP
TRAF_GUARD_PRECHECK: traf_guard_antiscanner -> LOG + DROP
FILTER_MOBILE_443: allowed_mobile_443 -> ACCEPT
FILTER_MOBILE_443: non-mobile -> LOG + DROP
```

## ASN allowlist

Дефолтный список пишется в:

```text
/opt/mobile443/asns.conf
```

Если файл уже существует, bootstrap его не перезаписывает. Можно редактировать список вручную и затем запустить обновление:

```bash
/usr/local/sbin/mobile443-update.sh
```

Префиксы ASN скачиваются через RIPEstat `announced-prefixes`.

## Исключения

Во время bootstrap можно добавить source IP или CIDR, которые должны проходить фильтр до Traffic Guard и mobile ASN проверки.

Поддерживаются одиночные IPv4-адреса и любые IPv4 CIDR-маски:

```text
203.0.113.10
203.0.113.0/24
10.0.0.0/8
```

Исключения хранятся в:

```text
/opt/mobile443/exceptions.conf
```

После обновления списков автоматически запускается:

```bash
/usr/local/sbin/mobile443-apply-exceptions.sh
```

Скрипт нормализует одиночные IP в `/32`, пропускает невалидные строки и загружает результат в `ipset mobile443_exceptions`.

## Traffic Guard списки

Используются списки:

```text
https://raw.githubusercontent.com/shadow-netlab/traffic-guard-lists/refs/heads/main/public/government_networks.list
https://raw.githubusercontent.com/shadow-netlab/traffic-guard-lists/refs/heads/main/public/antiscanner.list
```

Локальные копии:

```text
/opt/mobile443/lists/government_networks.list
/opt/mobile443/lists/antiscanner.list
```

## Проверка

```bash
systemctl status mobile443-update.timer --no-pager
systemctl status mobile443-update.service --no-pager
systemctl status mobile443-apply.service --no-pager

iptables -L TRAF_GUARD_PRECHECK -n -v --line-numbers
iptables -L FILTER_MOBILE_443 -n -v --line-numbers

ipset list traf_guard_government | head -20
ipset list traf_guard_antiscanner | head -20
ipset list allowed_mobile_443 | head -20
ipset list mobile443_exceptions | head -20
```

## Конфигурация

Основной файл:

```text
/opt/mobile443/config.conf
```

Дефолт:

```bash
PORTS="443"
ENABLE_TRAF_GUARD="true"
ENABLE_TRAF_GUARD_GOVERNMENT="true"
ENABLE_TRAF_GUARD_ANTISCANNER="true"
ENABLE_MOBILE_ALLOW="true"
TRAF_GUARD_BASE_URL="https://raw.githubusercontent.com/shadow-netlab/traffic-guard-lists/refs/heads/main/public"
```

## Предупреждение

Проект меняет SSH, firewall и sysctl. Запускайте bootstrap только на сервере, где есть аварийный доступ на случай rollback.
