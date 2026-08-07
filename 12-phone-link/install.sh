#!/usr/bin/env bash
# Instala o Phone Link (fatia 1: transporte). Idempotente.
set -euo pipefail

AQUI="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$HOME/.local/lib/phone"
BIN="$HOME/.local/bin"
UNIDADES="$HOME/.config/systemd/user"
ESTADO="$HOME/.local/state/phone"
RUNTIME="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/phone"

echo ">> conferindo dependencias"
command -v python3 >/dev/null || { echo "faltou python3"; exit 1; }
command -v openssl >/dev/null || { echo "faltou openssl"; exit 1; }

echo ">> instalando o pacote em $LIB"
mkdir -p "$LIB" "$BIN" "$UNIDADES"
rm -rf "$LIB/phoned"
cp -r "$AQUI/files/phoned" "$LIB/phoned"

# Lancador com o PYTHONPATH embutido, para a unit nao depender do ambiente herdado.
cat > "$LIB/run-phoned" <<EOF
#!/usr/bin/env bash
export PYTHONPATH="$LIB"
exec python3 -m phoned "\$@"
EOF
chmod +x "$LIB/run-phoned"

echo ">> instalando o phonectl em $BIN"
install -m 755 "$AQUI/files/phonectl" "$BIN/phonectl"

# O ReadWritePaths da unit exige que os dois diretorios ja existam antes do
# primeiro start: sem isto o systemd recusa montar o namespace com "No such
# file or directory" e o daemon nunca chega a rodar (confirmado com
# systemd-run --user de teste). O daemon cria os dois de novo sozinho, mas
# so depois que o processo ja subiu, o que e tarde demais para a montagem.
echo ">> preparando estado ($ESTADO) e diretorio de execucao ($RUNTIME)"
mkdir -p "$ESTADO" "$RUNTIME"
chmod 700 "$ESTADO" "$RUNTIME"

echo ">> instalando a unit do systemd"
# Reescreve por completo em vez de anexar, entao rodar de novo nao duplica nada.
sed -e "s|^ExecStart=.*|ExecStart=$LIB/run-phoned|" \
    -e "s|^ReadWritePaths=.*|ReadWritePaths=$ESTADO $RUNTIME|" \
    "$AQUI/files/phoned.service" > "$UNIDADES/phoned.service"

systemctl --user daemon-reload
systemctl --user enable --now phoned.service

echo
echo "pronto. Verifique com:"
echo "  systemctl --user status phoned"
echo "  phonectl list"
echo
echo "Se o PATH nao tiver ~/.local/bin, acrescente ao seu shell:"
echo '  export PATH="$HOME/.local/bin:$PATH"'
