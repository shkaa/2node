#!/bin/bash
# Посредник: сайт на этом VPS и проброс naive на основной сервер.
# Запуск на НОВОМ чистом Ubuntu/Debian от root:
#   bash install.sh
# Или одной ссылкой, когда файл лежит в git:
#   bash <(curl -fsSL https://raw.githubusercontent.com/shkaa/2node/main/install.sh)
# Ссылку клиента не меняет. После установки в ссылку подставляется IP этого VPS:
#   ?ip=АДРЕС_ЭТОГО_СЕРВЕРА
set -euo pipefail

ORIGIN="${ORIGIN:-}"
RELAY_NAME="${RELAY_NAME:-kakamba.work.gd}"
SITE_DOMAIN="${SITE_DOMAIN:-gosuslugi.win}"
NAIVE_USER=""
NAIVE_PASS=""
ASK_ORIGIN=1
ASK_NAME=1
ASK_DOMAIN=1

while [ $# -gt 0 ]; do
  case "$1" in
    --origin) ORIGIN="$2"; ASK_ORIGIN=0; shift 2 ;;
    --name) RELAY_NAME="$2"; ASK_NAME=0; shift 2 ;;
    --domain) SITE_DOMAIN="$2"; ASK_DOMAIN=0; shift 2 ;;
    *) echo "Неизвестный аргумент: $1"; exit 1 ;;
  esac
done

if [ "$(id -u)" -ne 0 ]; then
  echo "Запускай от root."
  exit 1
fi

valid_ipv4() {
  local ip="$1" o
  [[ "$ip" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
  for o in "${BASH_REMATCH[@]:1}"; do
    [ "$o" -le 255 ] || return 1
  done
}

urlencode() {
  local LC_ALL=C
  local s="$1" i c hex out=""
  for ((i = 0; i < ${#s}; i++)); do
    c="${s:i:1}"
    case "$c" in
      [a-zA-Z0-9._~-]) out+="$c" ;;
      *) printf -v hex '%%%02X' "'$c"; out+="$hex" ;;
    esac
  done
  printf '%s' "$out"
}

if [ -f /etc/caddy/Caddyfile ] && grep -q "forward_proxy" /etc/caddy/Caddyfile; then
  echo "Здесь уже основной naive-сервер. Этот скрипт ставится только на новый VPS."
  exit 1
fi

if [ -f /etc/nginx/nginx.conf ] && grep -q "ssl_preread" /etc/nginx/nginx.conf; then
  if [ ! -t 0 ]; then
    echo "Посредник уже настроен. Запусти скрипт из терминала и подтверди перезапись."
    exit 1
  fi
  read -r -p "Посредник уже стоит. Перезаписать конфиг и перезапустить? [y/N]: " _overwrite
  [[ "$_overwrite" =~ ^[Yy]$ ]] || { echo "Ничего не менял."; exit 1; }
  unset _overwrite
fi

if [ -t 0 ]; then
  if [ "$ASK_ORIGIN" = 1 ]; then
    while true; do
      read -r -p "IP основного сервера: " ORIGIN
      valid_ipv4 "$ORIGIN" && break
      echo "Нужен IPv4 нового основного. Старый адрес сам не подставляется."
    done
  fi
  if [ "$ASK_NAME" = 1 ]; then
    read -r -p "Имя в ссылке, его сертификат на основном [$RELAY_NAME]: " _v
    RELAY_NAME="${_v:-$RELAY_NAME}"
  fi
  if [ "$ASK_DOMAIN" = 1 ]; then
    read -r -p "Домен сайта на этом VPS [$SITE_DOMAIN]: " _v
    SITE_DOMAIN="${_v:-$SITE_DOMAIN}"
  fi
  read -r -p "Логин учётки (Enter — ссылку не собирать): " NAIVE_USER
  if [ -n "$NAIVE_USER" ]; then
    read -r -s -p "Пароль учётки: " NAIVE_PASS
    echo
  fi
  unset _v
fi

if ! valid_ipv4 "$ORIGIN"; then
  echo "Задай IP основного: ORIGIN=1.2.3.4 bash install.sh"
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y curl ca-certificates debian-keyring debian-archive-keyring apt-transport-https gnupg nginx libnginx-mod-stream ufw

systemctl stop nginx >/dev/null 2>&1 || true

if ! command -v caddy >/dev/null 2>&1; then
  rm -f /usr/share/keyrings/caddy-stable-archive-keyring.gpg
  curl -1sLf "https://dl.cloudsmith.io/public/caddy/stable/gpg.key" | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
  curl -1sLf "https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt" | tee /etc/apt/sources.list.d/caddy-stable.list >/dev/null
  apt-get update -qq
  apt-get install -y caddy
fi

mkdir -p /var/www/front
cat > /var/www/front/index.html << 'HTML'
<!DOCTYPE html>
<html lang="ru">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Северная полка — что читаю</title>
<style>
  :root { color-scheme: light; }
  * { box-sizing: border-box; }
  body { margin: 0; color: #241f1b; background: #efe6d8; font: 17px/1.55 "Iowan Old Style", Palatino, Georgia, serif; }
  a { color: inherit; }
  .wrap { max-width: 980px; margin: 0 auto; padding: 0 22px; }
  nav { display: flex; justify-content: space-between; align-items: baseline; padding: 22px 0 8px; font: 13px/1 sans-serif; letter-spacing: .12em; text-transform: uppercase; }
  nav a { text-decoration: none; margin-left: 18px; color: #5c5148; }
  nav strong { letter-spacing: .16em; font-weight: 600; }
  .hero { padding: 28px 0 10px; }
  .hero h1 { font-weight: normal; font-size: 56px; line-height: 1.02; margin: 0; }
  .hero p { max-width: 38em; font-size: 20px; color: #4a433c; }
  h2 { font: 12px/1 sans-serif; letter-spacing: .18em; text-transform: uppercase; color: #8a7b6d; margin: 36px 0 14px; }
  .grid { display: grid; grid-template-columns: repeat(3, 1fr); gap: 16px; }
  .book { background: #fbf6ee; border: 1px solid #e0d3c2; min-height: 230px; padding: 16px 16px 18px; display: flex; flex-direction: column; }
  .cover { height: 8px; margin: -16px -16px 16px; }
  .now .cover { background: #8c3f32; }
  .next .cover { background: #2f5d50; }
  .book h3 { font-size: 26px; font-weight: normal; line-height: 1.15; margin: 0 0 8px; }
  .who { margin: 0; color: #6b5e53; font-size: 15px; }
  .book p:last-child { margin: 14px 0 0; }
  .about { display: grid; grid-template-columns: 1.2fr .8fr; gap: 28px; padding-bottom: 20px; }
  .about p { margin-top: 0; }
  blockquote { margin: 0; padding: 18px 20px; background: #e7dccb; font-size: 20px; }
  blockquote span { display: block; margin-top: 10px; font: 13px/1.4 sans-serif; letter-spacing: .08em; text-transform: uppercase; color: #6b5e53; }
  footer { padding: 28px 0 48px; font: 13px/1.4 sans-serif; color: #8a7b6d; }
  @media (max-width: 800px) {
    .hero h1 { font-size: 40px; }
    .grid, .about { grid-template-columns: 1fr; }
  }
</style>
</head>
<body>
<div class="wrap">
  <nav>
    <strong>Северная полка</strong>
    <div>
      <a href="#now">Сейчас</a>
      <a href="#next">Дальше</a>
      <a href="#about">О полке</a>
    </div>
  </nav>
  <header class="hero">
    <h1>Книги, которые я читаю</h1>
    <p>Три открыты. Три ждут своей очереди. Это не магазин и не библиотечный каталог, просто моя полка на этот месяц.</p>
  </header>
  <main>
    <h2 id="now">Сейчас читаю</h2>
    <div class="grid now">
      <article class="book"><div class="cover"></div><h3>Мастер и Маргарита</h3><p class="who">Михаил Булгаков</p><p>Дочитываю вторую часть. Закладка стоит на бале, дальше только по вечерам.</p></article>
      <article class="book"><div class="cover"></div><h3>Пикник на обочине</h3><p class="who">Аркадий и Борис Стругацкие</p><p>Читаю заново и медленно. Хочу дойти до финала без спешки.</p></article>
      <article class="book"><div class="cover"></div><h3>1984</h3><p class="who">Джордж Оруэлл</p><p>Середина книги. Держу бумажный экземпляр, не экран.</p></article>
    </div>
    <h2 id="next">Готовлюсь читать</h2>
    <div class="grid next">
      <article class="book"><div class="cover"></div><h3>Солярис</h3><p class="who">Станислав Лем</p><p>Уже лежит на столе. Начну сразу после «Пикника».</p></article>
      <article class="book"><div class="cover"></div><h3>Сто лет одиночества</h3><p class="who">Габриэль Гарсиа Маркес</p><p>Толстая. Оставляю на длинные выходные, чтобы не рвать на куски.</p></article>
      <article class="book"><div class="cover"></div><h3>Имя розы</h3><p class="who">Умберто Эко</p><p>Хочу читать с карандашом и не в дороге.</p></article>
    </div>
    <h2 id="about">О полке</h2>
    <div class="about">
      <div>
        <p>Полка одна, бумажная. Сюда записываю только то, что реально открыто или уже стоит следующим. Прочитанное убираю, чтобы список не расползался.</p>
        <p>Если книга залеживается больше месяца, она выпадает из очереди. Значит, сейчас не её время.</p>
      </div>
      <blockquote>Читать одну, держать вторую на виду и не начинать третью, пока не закрыта первая.<span>правило полки</span></blockquote>
    </div>
  </main>
  <footer>Северная полка · книги этого месяца</footer>
</div>
</body>
</html>
HTML

cat > /etc/caddy/Caddyfile << EOF
{
  https_port 8443
  log {
    exclude http.log.error
  }
}

https://${SITE_DOMAIN}:8443 {
  root * /var/www/front
  file_server
  encode
}
EOF

caddy validate --config /etc/caddy/Caddyfile
systemctl enable caddy
systemctl restart caddy

LISTEN6=""
if [ -f /proc/net/if_inet6 ] && [ "$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null || echo 1)" = "0" ]; then
  LISTEN6="    listen [::]:443;"
fi

cat > /etc/nginx/nginx.conf << EOF
load_module /usr/lib/nginx/modules/ngx_stream_module.so;
user www-data;
worker_processes auto;
error_log /var/log/nginx/error.log;
pid /run/nginx.pid;
events { worker_connections 1024; }
stream {
  map \$ssl_preread_server_name \$upstream {
    ${SITE_DOMAIN} 127.0.0.1:8443;
    default ${ORIGIN}:443;
  }
  server {
    listen 443;
${LISTEN6}
    proxy_pass \$upstream;
    ssl_preread on;
    proxy_connect_timeout 5s;
    proxy_timeout 30m;
  }
}
EOF

nginx -t
systemctl enable nginx
systemctl restart nginx

SSH_PORT=22
if [ -n "${SSH_CONNECTION:-}" ]; then
  SSH_PORT="${SSH_CONNECTION##* }"
fi
[[ "$SSH_PORT" =~ ^[0-9]+$ ]] || SSH_PORT=22
ufw allow 22/tcp >/dev/null || true
ufw allow "${SSH_PORT}/tcp" >/dev/null || true
ufw allow 80/tcp >/dev/null || true
ufw allow 443/tcp >/dev/null || true
ufw allow 8080/tcp >/dev/null || true
ufw deny 8443/tcp >/dev/null || true
ufw --force enable >/dev/null || true

IP="$(curl -4 -fsS --max-time 8 https://api.ipify.org || true)"
echo
echo "Посредник запущен."
echo "Сайт: https://${SITE_DOMAIN}  (сертификат появится, когда A-запись смотрит на этот VPS, облако серое)"
echo "Проброс ${RELAY_NAME} -> ${ORIGIN}:443"
if [ -n "$IP" ]; then
  if [ "$IP" = "$ORIGIN" ]; then
    echo "Этот адрес совпал с основным сервером. Клиентскую ссылку не меняй."
  elif [ -n "$NAIVE_USER" ] && [ -n "$NAIVE_PASS" ]; then
    echo "Ссылка для клиента. На диск она не записана:"
    echo "naive+https://$(urlencode "$NAIVE_USER"):$(urlencode "$NAIVE_PASS")@${RELAY_NAME}:443?ip=${IP}"
  else
    echo "В ссылке клиента замени ip на: ?ip=${IP}"
  fi
else
  echo "Внешний IP не определился. Подставь адрес этого VPS в ?ip="
fi

if timeout 5 bash -c "echo >/dev/tcp/${ORIGIN}/443"; then
  echo "До основного ${ORIGIN}:443 соединение есть."
else
  echo "До основного ${ORIGIN}:443 не достучаться. Проброс не заработает, пока основной не слушает 443."
fi

if curl -fsS --max-time 20 --resolve "${RELAY_NAME}:443:127.0.0.1" "https://${RELAY_NAME}/" -o /dev/null; then
  echo "Проброс ${RELAY_NAME} через этот VPS отвечает, сертификат основного сошёлся."
else
  echo "Проброс поднят, но TLS ${RELAY_NAME} через него не сошёлся. Чаще всего на основном ещё нет сертификата."
fi
