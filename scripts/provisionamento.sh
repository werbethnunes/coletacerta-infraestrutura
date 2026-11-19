
#!/bin/bash

set -Eeuo pipefail

USUARIO="${SUDO_USER:-$(id -un)}"
HOME_USUARIO="$(getent passwd "$USUARIO" | cut -d: -f6)"
GRUPO_USUARIO="$(id -gn "$USUARIO")"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

APP_DIR="$HOME_USUARIO/coletacerta-mobile"
WEB_DIR="/var/www/coletacerta"
LOG_DIR="$PROJECT_DIR/logs"
LOG_FILE="$LOG_DIR/provisionamento.log"
CONFIG_FILE="$PROJECT_DIR/config/coletacerta"

mkdir -p "$LOG_DIR"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "=========================================="
echo "Provisionamento do ColetaCerta"
echo "Iniciado em: $(date)"
echo "=========================================="

if [ "$EUID" -ne 0 ]; then
    echo "Execute este script com sudo."
    exit 1
fi

if [ -z "$HOME_USUARIO" ] || [ ! -d "$HOME_USUARIO" ]; then
    echo "Não foi possível identificar o diretório do usuário."
    exit 1
fi

echo "Atualizando pacotes do sistema..."
apt update

echo "Instalando dependências..."
apt install -y nginx git curl htop

echo "Verificando Node.js..."

if ! node -v 2>/dev/null | grep -q '^v22\.'; then
    echo "Instalando Node.js 22..."
    curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
    apt install -y nodejs
fi

echo "Versões instaladas:"
node -v
npm -v

echo "Verificando repositório Mobile..."

if [ ! -d "$APP_DIR/.git" ]; then
    sudo -u "$USUARIO" git clone \
        https://github.com/werbethnunes/coletacerta-mobile.git \
        "$APP_DIR"
else
    echo "Repositório Mobile já existe."
fi

echo "Instalando dependências da aplicação..."
sudo -u "$USUARIO" bash -c 'cd "$1" && npm ci' _ "$APP_DIR"

echo "Gerando versão Web..."
sudo -u "$USUARIO" bash -c 'cd "$1" && npx expo export --platform web' _ "$APP_DIR"

if [ ! -f "$APP_DIR/dist/index.html" ]; then
    echo "Erro: arquivo dist/index.html não encontrado."
    exit 1
fi

if [ ! -f "$CONFIG_FILE" ]; then
    echo "Erro: configuração do Nginx não encontrada."
    exit 1
fi

echo "Preparando arquivos para publicação..."

TEMP_DIR="$(mktemp -d /var/www/coletacerta-build.XXXXXX)"

cp -r "$APP_DIR/dist/." "$TEMP_DIR/"
chown -R www-data:www-data "$TEMP_DIR"
chmod -R 755 "$TEMP_DIR"

echo "Configurando Nginx..."

cp "$CONFIG_FILE" /etc/nginx/sites-available/coletacerta

ln -sf /etc/nginx/sites-available/coletacerta \
    /etc/nginx/sites-enabled/coletacerta

rm -f /etc/nginx/sites-enabled/default

nginx -t

echo "Publicando aplicação..."

mkdir -p "$WEB_DIR"

find "$WEB_DIR" -mindepth 1 -maxdepth 1 -exec rm -rf {} +

cp -r "$TEMP_DIR/." "$WEB_DIR/"
rm -rf "$TEMP_DIR"

chown -R www-data:www-data "$WEB_DIR"
chmod -R 755 "$WEB_DIR"

systemctl enable nginx
systemctl restart nginx

echo "Verificando aplicação..."

if curl -fsS http://localhost > /dev/null; then
    echo "ColetaCerta Mobile disponível em http://localhost"
else
    echo "Falha ao acessar a aplicação."
    exit 1
fi

echo "Configurando monitoramento do sistema..."

install -m 755 "$SCRIPT_DIR/monitoramento.sh" \
    /usr/local/bin/coletacerta-monitoramento

install -d -o "$USUARIO" -g "$GRUPO_USUARIO" \
    /var/log/coletacerta

install -m 644 "$PROJECT_DIR/services/coletacerta-monitoramento@.service" \
    /etc/systemd/system/coletacerta-monitoramento@.service

systemctl daemon-reload

systemctl enable --now \
    "coletacerta-monitoramento@${USUARIO}.service"

echo "Serviço de monitoramento instalado e habilitado."

echo "=========================================="
echo "Provisionamento concluído em $(date)"
echo "Aplicação: http://localhost"
echo "Monitoramento: ativo"
echo "=========================================="
