# Changelog

## [Unreleased]

### Added

- Интерактивный `bootstrap.sh` из `vpn-bootstrap`: hostname, SSH port, root SSH key, SSH hardening, Docker, Zsh, Speedtest CLI, sysctl tuning.
- Опциональный VPN defense profile с conntrack/backlog tuning, RPS/RFS и `iptables` hashlimit chains.
- Опциональная установка XanMod LTS kernel.
- `install.sh` для one-line установки с GitHub.
- `mobile443` runtime scripts:
  - `scripts/mobile443-common.sh`;
  - `scripts/mobile443-update.sh`;
  - `scripts/mobile443-apply-cache.sh`;
  - `scripts/mobile443-apply-exceptions.sh`.
- `systemd` units:
  - `mobile443-update.service`;
  - `mobile443-update.timer`;
  - `mobile443-apply.service`.
- Дефолтный `/opt/mobile443/asns.conf` со списком мобильных ASN.
- Интерактивный вопрос для добавления source IP/CIDR исключений в `/opt/mobile443/exceptions.conf`.
- `ipset mobile443_exceptions`, который применяется раньше Traffic Guard и mobile ASN проверки.

### Changed

- Traffic Guard из `vpn-bootstrap` заменён на логику из `mobile443-filter`.
- Вместо общего `ipset blacklist` используются отдельные sets `traf_guard_government`, `traf_guard_antiscanner` и `allowed_mobile_443`.
- На фильтруемых портах сначала применяется Traffic Guard precheck, затем разрешаются только IP из mobile ASN allowlist.
- Telegram/Remnawave мониторинг и уведомления из `mobile443-filter` не включены.
- `install.sh` теперь скачивает архив `wh3r3ar3you/mobile443upd`.
