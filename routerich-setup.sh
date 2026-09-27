#!/bin/sh
# ============================================================================
#  Универсальная настройка Routerich (OpenWrt) под нашу схему.
#  Идемпотентно: можно гонять повторно на любом боксе.
#
#  Что делает:
#    1. DoH: ровно два инстанса — Google (5053) и Cloudflare (5054)
#    2. DoT (stubby): Cloudflare + Google как третий слой
#    3. dns-failsafe-proxy: primary = mihomo, fallback = Google DoH
#    4. dnsmasq: strict-order — порядок опроса детерминирован
#    5. internet-detector: TCP/443 на Яндекс + Google (не ICMP и не TCP/53)
#    6. watchdog policy-routing TPROXY (cron, каждые 2 минуты)
#
#  Запуск:  ssh root@<роутер> 'sh -s' < routerich-setup.sh
#  Откат:   бэкап uci пишется в /root/uci-backup-<дата>/ первым шагом
# ============================================================================
set -u

say() { echo "  $*"; }
hr()  { echo; echo "== $* =="; }

BK="/root/uci-backup-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$BK"
for c in doh-proxy stubby dns-failsafe-proxy dhcp internet-detector; do
    uci export "$c" > "$BK/$c" 2>/dev/null
done
hr "Бэкап uci"; say "$BK"

# ---------------------------------------------------------------------------
# 1. DoH: Google + Cloudflare, по одному инстансу на порт
# ---------------------------------------------------------------------------
hr "DoH: Google 5053 + Cloudflare 5054"
while uci -q delete doh-proxy.@doh-proxy[-1]; do :; done   # снести все инстансы

add_doh() { # url  port  bootstrap
    uci add doh-proxy doh-proxy > /dev/null
    uci set doh-proxy.@doh-proxy[-1].resolver_url="$1"
    uci set doh-proxy.@doh-proxy[-1].listen_addr='127.0.0.1'
    uci set doh-proxy.@doh-proxy[-1].listen_port="$2"
    uci set doh-proxy.@doh-proxy[-1].bootstrap_dns="$3"
    uci set doh-proxy.@doh-proxy[-1].user='nobody'
    uci set doh-proxy.@doh-proxy[-1].group='nogroup'
    say "$1 → 127.0.0.1:$2"
}
add_doh 'https://dns.google/dns-query'        5053 '8.8.8.8,8.8.4.4'
add_doh 'https://cloudflare-dns.com/dns-query' 5054 '1.1.1.1,1.0.0.1'

# doh-proxy НЕ должен сам лезть в dnsmasq: иначе он допишет туда 5053/5054
# отдельными апстримами, dnsmasq начнёт выбирать между ними произвольно,
# и цепочка failsafe (primary → fallback) перестанет работать как задумано.
uci set doh-proxy.config.dnsmasq_config_update='-'
say "dnsmasq_config_update='-' (список апстримов ведём сами)"
# canary-домены: при включённых опциях doh-proxy дописывает в dnsmasq NXDOMAIN-заглушки
# /mask.icloud.com/, /mask-h2.icloud.com/, /use-application-dns.net/. Полезные сами по
# себе, но список апстримов мы ведём сами, и они остаются в нём мусором. Снимаем ради
# одинакового состояния на всех боксах.
uci -q delete doh-proxy.config.canary_domains_icloud
uci -q delete doh-proxy.config.canary_domains_mozilla
uci commit doh-proxy

# ---------------------------------------------------------------------------
# 2. DoT (stubby) — третий слой, если оба DoH лягут
# ---------------------------------------------------------------------------
hr "DoT (stubby): Cloudflare + Google"
while uci -q delete stubby.@resolver[-1]; do :; done
add_dot() { # ip  tls_auth_name
    uci add stubby resolver > /dev/null
    uci set stubby.@resolver[-1].address="$1"
    uci set stubby.@resolver[-1].tls_auth_name="$2"
    say "$1 ($2)"
}
add_dot '1.1.1.1' 'cloudflare-dns.com'
add_dot '8.8.8.8' 'dns.google'
uci commit stubby

# ---------------------------------------------------------------------------
# 3. failsafe: primary = mihomo, fallback = Google DoH
# ---------------------------------------------------------------------------
# ЗАЧЕМ ИМЕННО ТАК. У mihomo есть свой DNS-кэш и своя политика (RU → Яндекс
# напрямую, зарубеж → DoH через ноду). У dnsmasq кэш ПРИНУДИТЕЛЬНО выключен
# SSClash'ем (cachesize=0), поэтому каждый клиентский запрос уходит апстриму.
# Замер на живом боксе, повторные резолвы:
#     клиенту отвечает DoH-стек  → 0.065 с   (кэша нет нигде)
#     клиенту отвечает mihomo    → 0.003 с   (кэш mihomo)   ← ~20x быстрее
# Плюс уходит двойная работа: mihomo всё равно переразрешает домен после
# sniffer (override-destination: true), и теперь оба пути греют один кэш.
#
# Почему primary прописан в failsafe, а не первым в списке dnsmasq: SSClash при
# каждом старте дописывает свою запись 127.0.0.1#7874 в КОНЕЦ списка (add_list),
# то есть порядок неуправляем. Через failsafe mihomo оказывается первым при
# любом порядке — либо напрямую, либо как primary failsafe.
#
# Отказ mihomo проверен: clash остановлен → failsafe уходит на Google DoH
# мгновенно (ICMP port unreachable на loopback, а не по таймауту), DNS живёт.
hr "dns-failsafe-proxy: mihomo → Google DoH"
uci set dns-failsafe-proxy.main.listen_ip='127.0.0.1'
uci set dns-failsafe-proxy.main.listen_port='5359'
uci set dns-failsafe-proxy.main.dns_ip='127.0.0.1'
uci set dns-failsafe-proxy.main.dns_port='7874'       # mihomo
uci set dns-failsafe-proxy.main.failback_ip='127.0.0.1'
uci set dns-failsafe-proxy.main.failback_port='5053'  # Google DoH
uci set dns-failsafe-proxy.main.session_timeout='500'
uci set dns-failsafe-proxy.main.connect_timeout='150'
uci commit dns-failsafe-proxy
say "primary 7874 (mihomo) → fallback 5053 (Google DoH), timeout 500 мс"

# ---------------------------------------------------------------------------
# 4. dnsmasq: детерминированный порядок опроса
# ---------------------------------------------------------------------------
hr "dnsmasq: strict-order + апстрим 127.0.0.1#5359"
for p in 5053 5054 5055 5359 5453; do
    uci -q del_list dhcp.@dnsmasq[0].server="127.0.0.1#$p"
done
for d in '/mask.icloud.com/' '/mask-h2.icloud.com/' '/use-application-dns.net/'; do
    uci -q del_list dhcp.@dnsmasq[0].server="$d"
done
uci add_list dhcp.@dnsmasq[0].server='127.0.0.1#5359'
# Без strict-order dnsmasq сам выбирает апстрим и может постоянно ходить в DoH,
# минуя кэш mihomo — наблюдали ровно это: floor 53 мс на каждом запросе.
uci set dhcp.@dnsmasq[0].strictorder='1'
uci commit dhcp
say "$(uci get dhcp.@dnsmasq[0].server | tr ' ' ' ')  strictorder=1"
say "запись 7874 SSClash добавит сам — mihomo первый при любом порядке"

# ---------------------------------------------------------------------------
# 5. internet-detector: TCP/443 на Яндекс + Google
# ---------------------------------------------------------------------------
hr "internet-detector: TCP/443 Яндекс + Google"
# check_type (main.lua:46):  0 = TCP-connect на tcp_port, 1 = ICMP ping, 2 = curl по urls
# Порт 443, а не 53: TCP/53 к публичным резолверам отвечает нестабильно
# (замеры давали таймауты на обоих боксах) → детектор ловил бы ложные обрывы.
# По 443 Яндекс отдаёт DoH, Google тоже — проверено, стабильно.
uci -q delete internet-detector.internet.hosts
uci add_list internet-detector.internet.hosts='77.88.8.8'
uci add_list internet-detector.internet.hosts='8.8.8.8'
uci set internet-detector.internet.check_type='0'
uci set internet-detector.internet.tcp_port='443'
uci set internet-detector.internet.connection_attempts='2'
uci set internet-detector.internet.connection_timeout='3'
uci set internet-detector.internet.interval_up='30'
uci set internet-detector.internet.interval_down='5'
uci commit internet-detector
say "hosts: $(uci get internet-detector.internet.hosts | tr ' ' ' ')  tcp_port=443"
# Вариант «только РФ, без зарубежных IP»: тогда ICMP, т.к. на 195.208.4.1 нет 443
#   uci -q delete internet-detector.internet.hosts
#   uci add_list internet-detector.internet.hosts='77.88.8.8'
#   uci add_list internet-detector.internet.hosts='195.208.4.1'
#   uci set internet-detector.internet.check_type='1'

# ---------------------------------------------------------------------------
# 6. Watchdog policy-routing TPROXY
# ---------------------------------------------------------------------------
# Ловили живьём: у ssclash пропали `ip rule fwmark 0x1 → table 100` и
# `local default dev lo` в таблице 100. Помеченные пакеты перестали попадать
# в сокет mihomo и ушли в WAN напрямую. Симптом обманчивый: DIRECT-сайты
# открываются, всё проксируемое — нет, и выглядит как поломка DNS.
# Своего авторемонта у ssclash нет: в cron только `clash-rules update`,
# а hotplug 40-clash обновляет провайдеры, но не маршрутизацию.
hr "watchdog policy-routing (cron */2)"
cat > /opt/clash/bin/clash-policy-wd <<'WDEOF'
#!/bin/sh
# Штатный clash-rules validate_policy ненадёжен: он ищет литерал "lookup 100",
# а если таблица 100 названа в /etc/iproute2/rt_tables (на части прошивок
# Routerich это "zeroblock") — всегда рапортует failed. Проверяем сами.
pgrep -f '/opt/clash/bin/clash -d' >/dev/null 2>&1 || exit 0
rule_ok()  { ip rule 2>/dev/null | grep -q 'fwmark 0x1 '; }
route_ok() { [ -n "$(ip route show table 100 2>/dev/null)" ]; }
rule_ok && route_ok && exit 0
logger -t clash-policy-wd "policy routing сломан → ремонт"
/opt/clash/bin/clash-rules repair_policy >/dev/null 2>&1
sleep 2
if rule_ok && route_ok; then
    logger -t clash-policy-wd "восстановлено"
else
    logger -t clash-policy-wd "ремонт не помог → рестарт clash"
    /etc/init.d/clash restart >/dev/null 2>&1
fi
WDEOF
chmod +x /opt/clash/bin/clash-policy-wd
crontab -l 2>/dev/null | grep -v clash-policy-wd > /tmp/ct.$$ 2>/dev/null
echo '*/2 * * * * /opt/clash/bin/clash-policy-wd' >> /tmp/ct.$$
crontab /tmp/ct.$$; rm -f /tmp/ct.$$
/etc/init.d/cron restart >/dev/null 2>&1
say "установлен, проверка каждые 2 минуты"

# ---------------------------------------------------------------------------
# Перезапуск сервисов
# ---------------------------------------------------------------------------
hr "Перезапуск"
for s in doh-proxy stubby dns-failsafe-proxy internet-detector dnsmasq; do
    [ -x "/etc/init.d/$s" ] || continue
    /etc/init.d/$s restart >/dev/null 2>&1
    say "$s перезапущен"
done
sleep 5

# Проверяем по факту (слушает порт), а не по коду возврата init-скрипта:
# у doh-proxy при сносе старых инстансов restart возвращает非0, хотя всё поднялось.
for pp in "5053 doh-proxy/Google" "5054 doh-proxy/Cloudflare" "5359 failsafe" "5453 stubby"; do
    p="${pp%% *}"; n="${pp#* }"
    if netstat -lnup 2>/dev/null | grep -q "127.0.0.1:$p"; then
        say "$n :$p слушает"
    else
        say "$n :$p НЕ СЛУШАЕТ ← разобраться"
    fi
done

# ---------------------------------------------------------------------------
# Проверка
# ---------------------------------------------------------------------------
hr "Проверка"
say "слушают: $(netstat -lnup 2>/dev/null | grep -oE '127.0.0.1:(5053|5054|5359|5453|7874)' | sort -u | tr '\n' ' ')"
say "детектор: $(/etc/init.d/internet-detector status 2>&1 | head -1)"
for d in ya.ru github.com; do
    say "$d: $(nslookup $d 127.0.0.1 2>/dev/null | awk '/^Name:/{f=1;next} f&&/^Address/{print $NF; exit}')"
done
say "задержка резолва: $(curl -s -o /dev/null -w 'namelookup=%{time_namelookup} total=%{time_total}' -m 12 https://ya.ru 2>/dev/null)"
echo
say "откат: uci import < $BK/<файл> && uci commit && перезапуск сервиса"
