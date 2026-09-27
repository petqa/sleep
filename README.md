# mihomo для роутеров

Шаблоны конфигов mihomo: весь трафик через VPN, RU/BY-ресурсы напрямую по спискам [roscomvpn](https://github.com/hydraponique/roscomvpn-routing).

| файл | платформа | путь на устройстве |
|---|---|---|
| `openwrt-ssclash-nolab.yaml` | OpenWrt + [SSClash](https://github.com/zerolabnet/SSClash), режим TPROXY | `/opt/clash/config.yaml` |
| `keenetic-xkeen-nolab.yaml` | Keenetic + [XKeen](https://github.com/jameszeroX/XKeen), режим Hybrid | `/opt/etc/mihomo/config.yaml` |
| `routerich-setup.sh` | OpenWrt: DNS-стек, детектор интернета, watchdog | `ssh root@<роутер> 'sh -s' < routerich-setup.sh` |

Перед деплоем:

1. Подставить ссылку своей подписки вместо `https://sub.example.com/TOKEN`.
2. Для SSClash заменить `[HWID]` и `[HOSTNAME]` в `header:` на значения бокса.
3. Проверить конфиг на устройстве: `mihomo -d <каталог с config.yaml> -t`, и только потом перезапускать (`/etc/init.d/clash restart` или `xkeen -restart`).
