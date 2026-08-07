#!/usr/bin/env bash
# Instala o Phone Link (fatia 1: transporte). Idempotente.
set -euo pipefail

AQUI="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$HOME/.local/lib/phone"
BIN="$HOME/.local/bin"
UNIDADES="$HOME/.config/systemd/user"
ESTADO="$HOME/.local/state/phone"
RUNTIME="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/phone"

# ATENCAO: nao troque isto por um chmod aqui. O RUNTIME e coberto pelo
# RuntimeDirectory=phone dentro da propria unit (files/phoned.service), que o
# systemd recria em %t/phone a cada start, antes de montar o namespace. Um
# mkdir feito so aqui, na instalacao, sobreviveria ate o proximo reboot: o
# XDG_RUNTIME_DIR e tmpfs e volta vazio, e o servico morreria em loop de
# restart no primeiro boot depois de instalado (esse foi o defeito que a
# revisao encontrou). O ESTADO nao tem essa protecao (nao ha
# StateDirectory= na unit, so ReadWritePaths=), entao continua precisando
# ser criado aqui.

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

# O ReadWritePaths da unit exige que o caminho ja exista antes do primeiro
# start: sem isto o systemd recusa montar o namespace com "No such file or
# directory" e o daemon nunca chega a rodar (confirmado com systemd-run
# --user de teste). O RUNTIME nao entra aqui: e RuntimeDirectory=phone na
# propria unit que cuida dele, a cada start, ver comentario acima.
echo ">> preparando o diretorio de estado ($ESTADO)"
mkdir -p "$ESTADO"
chmod 700 "$ESTADO"

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
