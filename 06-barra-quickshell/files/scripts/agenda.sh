#!/bin/bash
# Agenda e feriados do calendario do Quickshell.
#
# Tudo em arquivo local, decisao dele: funciona offline, nao depende de conta
# nem de credencial do Google, e sobrevive a reinstalacao do shell.
#
#   eventos  -> ~/.local/share/quickshell/agenda.json      (dado dele, nao apagar)
#   feriados -> ~/.local/state/quickshell-feriados-ANO.json (cache, descartavel)
#
# A saida e sempre JSON numa linha, para o QML fazer JSON.parse direto. Erro
# vira JSON vazio ([] ou {}), nunca texto solto: o parse do QML quebraria e a
# tela ficaria em branco sem dizer o porque.

set -u

AGENDA="${XDG_DATA_HOME:-$HOME/.local/share}/quickshell/agenda.json"
CACHE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}"

# ---------------------------------------------------------------- feriados
# Nacionais vem da BrasilAPI, que ja calcula as datas moveis (Carnaval, Sexta
# Santa, Corpus Christi) sem eu ter que implementar computus.
#
# Estaduais e municipais NAO existem naquela API: ela devolve so `national`,
# conferido em 14/08/2026. Ficam na tabela abaixo, todos de data fixa, entao
# nao quebram de um ano pro outro.
#
# Fonte: calendario oficial de feriados e pontos facultativos do TJTO para 2026.
# Ha divergencia publica sobre 15/08 e 08/09: sites de calendario tratam como
# ponto facultativo, o TJTO trata como feriado, citando a Lei 4.509/2024 no caso
# do 15/08. Seguimos o TJTO, que e a fonte oficial e a mais recente.
#
# PONTOS FACULTATIVOS de proposito FORA da lista: 18/03 (Autonomia do Estado),
# 20/04, 04/06, 05/06 e 10/08. Nao sao feriado, e marcar como se fosse faria o
# calendario mentir.
FIXOS_TO='[
  {"dia":"03-19","nome":"Dia de São José","tipo":"municipal"},
  {"dia":"05-20","nome":"Aniversário de Palmas","tipo":"municipal"},
  {"dia":"08-15","nome":"Dia do Senhor do Bonfim","tipo":"estadual"},
  {"dia":"09-08","nome":"Nossa Senhora da Natividade","tipo":"estadual"},
  {"dia":"10-05","nome":"Criação do Estado do Tocantins","tipo":"estadual"}
]'

cmd_feriados() {
    local ano="${1:-$(date +%Y)}"
    local cache="$CACHE_DIR/quickshell-feriados-$ano.json"

    # Baixa so se ainda nao tem. Feriado nacional nao muda no meio do ano, entao
    # revalidar toda hora so gastaria rede e deixaria o painel lento offline.
    if [ ! -s "$cache" ]; then
        local bruto
        bruto="$(timeout 12 curl -s "https://brasilapi.com.br/api/feriados/v1/$ano" 2>/dev/null)"
        # so grava se veio JSON de verdade: gravar resposta de erro envenena o
        # cache e o calendario fica sem feriado nacional ate alguem apagar na mao
        case "$bruto" in
            \[*) printf '%s' "$bruto" > "$cache" ;;
        esac
    fi

    ANO="$ano" CACHE="$cache" FIXOS="$FIXOS_TO" python3 - <<'PY'
import json, os
ano = os.environ["ANO"]
saida = []
try:
    with open(os.environ["CACHE"]) as f:
        for h in json.load(f):
            saida.append({"data": h["date"], "nome": h["name"], "tipo": "nacional"})
except Exception:
    pass                      # sem rede e sem cache: ficam so os locais
for h in json.loads(os.environ["FIXOS"]):
    saida.append({"data": f"{ano}-{h['dia']}", "nome": h["nome"], "tipo": h["tipo"]})
saida.sort(key=lambda x: x["data"])
print(json.dumps(saida, ensure_ascii=False))
PY
}

# ---------------------------------------------------------------- eventos
# Formato de um evento:
#   {"id": "1786745000123", "data": "2026-08-20", "hora": "19:30",
#    "titulo": "...", "avisos": [0, 10, 60], "avisados": [10]}
#
# `avisos` sao MINUTOS ANTES; 0 e "na hora". `avisados` guarda os que ja
# dispararam, senao o alarme tocaria de novo a cada varredura do timer.

_py() {
    AGENDA="$AGENDA" python3 - "$@"
}

cmd_listar() {
    _py <<'PY'
import json, os
try:
    with open(os.environ["AGENDA"]) as f:
        d = json.load(f)
    if not isinstance(d, list): d = []
except Exception:
    d = []
print(json.dumps(d, ensure_ascii=False))
PY
}

# add <data> <hora> <titulo> <avisos-csv>
cmd_add() {
    _py "$1" "$2" "$3" "${4:-0}" <<'PY'
import json, os, sys, time
data, hora, titulo, avisos = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
p = os.environ["AGENDA"]
os.makedirs(os.path.dirname(p), exist_ok=True)
try:
    with open(p) as f: d = json.load(f)
    if not isinstance(d, list): d = []
except Exception:
    d = []
mins = sorted({int(x) for x in avisos.split(",") if x.strip().lstrip("-").isdigit()})
d.append({"id": str(int(time.time() * 1000)), "data": data, "hora": hora,
          "titulo": titulo, "avisos": mins or [0], "avisados": []})
d.sort(key=lambda e: (e["data"], e["hora"]))
tmp = p + ".tmp"
with open(tmp, "w") as f: json.dump(d, f, ensure_ascii=False)
os.replace(tmp, p)          # atomico: o QML le esse arquivo e nao pode ver metade
print(json.dumps(d, ensure_ascii=False))
PY
}

cmd_del() {
    _py "$1" <<'PY'
import json, os, sys
alvo = sys.argv[1]; p = os.environ["AGENDA"]
try:
    with open(p) as f: d = json.load(f)
except Exception:
    d = []
d = [e for e in d if e.get("id") != alvo]
tmp = p + ".tmp"
os.makedirs(os.path.dirname(p), exist_ok=True)
with open(tmp, "w") as f: json.dump(d, f, ensure_ascii=False)
os.replace(tmp, p)
print(json.dumps(d, ensure_ascii=False))
PY
}

# marca um aviso como ja disparado
cmd_avisado() {
    _py "$1" "$2" <<'PY'
import json, os, sys
alvo, minuto = sys.argv[1], int(sys.argv[2]); p = os.environ["AGENDA"]
try:
    with open(p) as f: d = json.load(f)
except Exception:
    d = []
for e in d:
    if e.get("id") == alvo and minuto not in e.get("avisados", []):
        e.setdefault("avisados", []).append(minuto)
tmp = p + ".tmp"
os.makedirs(os.path.dirname(p), exist_ok=True)
with open(tmp, "w") as f: json.dump(d, f, ensure_ascii=False)
os.replace(tmp, p)
print(json.dumps(d, ensure_ascii=False))
PY
}

case "${1:-}" in
    feriados) cmd_feriados "${2:-}" ;;
    listar)   cmd_listar ;;
    add)      cmd_add "${2:-}" "${3:-}" "${4:-}" "${5:-0}" ;;
    del)      cmd_del "${2:-}" ;;
    avisado)  cmd_avisado "${2:-}" "${3:-0}" ;;
    *) echo "uso: agenda.sh <feriados [ano]|listar|add data hora titulo avisos|del id|avisado id min>" >&2; exit 1 ;;
esac
