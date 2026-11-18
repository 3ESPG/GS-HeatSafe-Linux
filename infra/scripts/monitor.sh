#!/usr/bin/env bash
# =============================================================================
# HeatSafe · monitor.sh  (critério: monitoramento de infra com alertas de CPU,
#                          disco e memória)
#
# Daemon que roda como serviço systemd (heatsafe-monitor.service). A cada
# MON_INTERVAL segundos:
#   - mede CPU (/proc/stat), memória (/proc/meminfo) e disco (df)
#   - verifica os serviços do HeatSafe (systemd + resposta HTTP)
#   - detecta reinícios automáticos feitos pelo systemd (NRestarts)
#   - gera ALERTA / CRITICO / RESOLVIDO em /var/log/heatsafe/alertas.log,
#     no journald (logger) e, se configurado, num webhook (Discord/Slack/Teams)
#   - grava uma linha por ciclo em /var/log/heatsafe/monitor.log
#   - publica /var/www/heatsafe-status/status.json (página http://heatsafe.local)
#   - "bate o coração" (heartbeat) para o healthcheck saber que não travou
#
# Anti-spam: um alerta só é emitido quando o nível MUDA (OK->ALERTA->CRITICO->OK);
# se continuar ativo, é repetido a cada MON_REPEAT_MIN minutos. CPU só alerta
# depois de MON_CPU_SUSTAIN leituras seguidas acima do limite (ignora picos).
#
# Uso: normalmente via systemd. Para testar à mão: sudo -u heatsafe ./monitor.sh
#      ./monitor.sh --uma-vez   (faz uma leitura, imprime e sai)
# =============================================================================
set -uo pipefail
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/common.sh"
HS_SCRIPT=monitor.sh

MON_LOG="$HS_LOG/monitor.log"
ALERT_LOG="$HS_LOG/alertas.log"
STATE_DIR="$HS_DATA/monitor"
HEARTBEAT="$STATE_DIR/heartbeat"
STATUS_JSON="$HS_STATUS_DIR/status.json"
SERVICOS_APP=(heatsafe-api heatsafe-previsao)

declare -A NIVEL=() ULTIMO_AVISO=() RESTARTS=()
CPU_ACIMA=0
CPU_TOTAL_ANT=0
CPU_IDLE_ANT=0

agora() { date '+%Y-%m-%d %H:%M:%S'; }

mlog() {
  local linha; linha="[$(agora)] $*"
  echo "$linha"
  echo "$linha" >> "$MON_LOG" 2>/dev/null
}

enviar_webhook() {
  local texto="HeatSafe [$1] $(hostname): $2" payload
  payload=$(jq -cn --arg t "$texto" '{content: $t, text: $t}')
  curl -s -m 5 -H 'Content-Type: application/json' -d "$payload" "$ALERT_WEBHOOK_URL" >/dev/null 2>&1
}

# alerta NIVEL MENSAGEM  -> alertas.log + journald + webhook
alerta() {
  local nivel=$1 msg=$2 prio linha
  linha="[$(agora)] [$nivel] $msg"
  echo "$linha"
  echo "$linha" >> "$ALERT_LOG" 2>/dev/null
  case $nivel in
    CRITICO)              prio=crit ;;
    ALERTA)               prio=warning ;;
    *)                    prio=notice ;;
  esac
  logger -p "user.$prio" -t heatsafe-monitor -- "[$nivel] $msg" 2>/dev/null
  [[ -n ${ALERT_WEBHOOK_URL:-} ]] && enviar_webhook "$nivel" "$msg" &
}

# transicao CHAVE NOVO_NIVEL MSG_PROBLEMA MSG_NORMAL
# Emite alerta só quando o nível muda, ou repete se o problema persiste há MON_REPEAT_MIN.
transicao() {
  local chave=$1 novo=$2 msg_prob=$3 msg_ok=$4
  local antigo=${NIVEL[$chave]:-OK} t; t=$(date +%s)
  if [[ $novo != "$antigo" ]]; then
    if [[ $novo == OK ]]; then
      alerta RESOLVIDO "$msg_ok"
    else
      alerta "$novo" "$msg_prob"
    fi
    NIVEL[$chave]=$novo
    ULTIMO_AVISO[$chave]=$t
  elif [[ $novo != OK ]] && (( t - ${ULTIMO_AVISO[$chave]:-0} >= MON_REPEAT_MIN * 60 )); then
    alerta "$novo" "$msg_prob (continua ativo)"
    ULTIMO_AVISO[$chave]=$t
  fi
}

# avaliar CHAVE VALOR LIMITE_ALERTA LIMITE_CRITICO DESCRICAO [DETALHE]
avaliar() {
  local chave=$1 valor=$2 warn=$3 crit=$4 desc=$5 extra=${6:-} novo=OK limite=""
  if (( valor >= crit )); then novo=CRITICO; limite=$crit
  elif (( valor >= warn )); then novo=ALERTA; limite=$warn; fi
  transicao "$chave" "$novo" \
    "$desc em ${valor}% (limite ${limite}%)${extra:+ | $extra}" \
    "$desc normalizado: ${valor}% (alerta a partir de ${warn}%)"
}

# ---------- Métricas ----------
ler_cpu() {
  local _rotulo u n s i w q sq st
  read -r _rotulo u n s i w q sq st _ < /proc/stat
  CPU_TOTAL=$((u + n + s + i + w + q + sq + st))
  CPU_IDLE=$((i + w))
}
# Uso de CPU desde a leitura anterior -> CPU_PCT
# (não chamar dentro de $(...): o subshell perderia a leitura anterior)
medir_cpu() {
  ler_cpu
  local dt=$((CPU_TOTAL - CPU_TOTAL_ANT)) di=$((CPU_IDLE - CPU_IDLE_ANT))
  CPU_TOTAL_ANT=$CPU_TOTAL; CPU_IDLE_ANT=$CPU_IDLE
  CPU_PCT=0
  (( dt > 0 )) && CPU_PCT=$(( (100 * (dt - di)) / dt ))
  return 0
}
top_processos() {  # top_processos cpu|mem
  local campo=%$1
  ps -eo pid=,comm=,"$campo"= --sort=-"$campo" 2>/dev/null | head -3 \
    | awk -v c="$1" '{printf "%s%s(pid %s) %s%%", (NR>1?", ":""), $2, $1, $3} END{if(NR) printf ""}' \
    | sed "s/^/maiores consumidores de $1: /"
}
mem_info() {  # imprime: pct usado_MB total_MB
  awk '/^MemTotal:/{t=$2} /^MemAvailable:/{a=$2} END{printf "%d %d %d", (t-a)*100/t, (t-a)/1024, t/1024}' /proc/meminfo
}

# ---------- Ciclo de verificação ----------
verificar() {
  local cpu mem mem_usado mem_total load
  medir_cpu; cpu=$CPU_PCT
  read -r mem mem_usado mem_total < <(mem_info)
  load=$(cut -d' ' -f1-3 /proc/loadavg)

  # CPU (com sustentação para não alertar em picos de 1 leitura)
  if (( cpu >= CPU_WARN )); then CPU_ACIMA=$((CPU_ACIMA + 1)); else CPU_ACIMA=0; fi
  if (( cpu < CPU_WARN || CPU_ACIMA >= MON_CPU_SUSTAIN )); then
    local extra_cpu=""
    (( cpu >= CPU_WARN )) && extra_cpu="load ${load// / / } | $(top_processos cpu)"
    avaliar cpu "$cpu" "$CPU_WARN" "$CPU_CRIT" "Uso de CPU" "$extra_cpu"
  fi

  # Memória
  local extra_mem=""
  (( mem >= MEM_WARN )) && extra_mem="${mem_usado}/${mem_total} MB | $(top_processos mem)"
  avaliar mem "$mem" "$MEM_WARN" "$MEM_CRIT" "Uso de memória" "$extra_mem"

  # Disco (cada sistema de arquivos uma vez só)
  local m dev pct alvo livre_k vistos=" " discos_txt="" discos_json="[]"
  for m in $DISK_MOUNTS; do
    read -r dev pct alvo livre_k < <(df -P "$m" 2>/dev/null | awk 'NR==2{gsub("%","",$5); print $1, $5, $6, $4}')
    [[ -z ${alvo:-} || $vistos == *" $alvo "* ]] && continue
    vistos+="$alvo "
    avaliar "disco:$alvo" "$pct" "$DISK_WARN" "$DISK_CRIT" "Uso de disco em $alvo" "livre: $((livre_k / 1024)) MB ($dev)"
    discos_txt+=" $alvo=${pct}%"
    discos_json=$(jq -c --arg m "$alvo" --argjson p "$pct" --argjson l "$((livre_k / 1024))" \
      '. + [{montagem: $m, uso_pct: $p, livre_mb: $l}]' <<<"$discos_json")
  done

  # Serviços: estado no systemd + resposta HTTP + reinícios automáticos
  local svc estado code url n pid svc_txt="" servicos_json="[]" nivel_svc
  for svc in "${SERVICOS_APP[@]}"; do
    servico_existe "$svc" || continue
    estado=$(systemctl is-active "$svc" 2>/dev/null)
    case $svc in
      heatsafe-api)      url="http://127.0.0.1:$API_PORT$API_HEALTH_PATH" ;;
      heatsafe-previsao) url="http://127.0.0.1:$PREVISAO_PORT$PREVISAO_HEALTH_PATH" ;;
    esac
    code="---"
    nivel_svc=OK
    if [[ $estado == active ]]; then
      code=$(http_code "$url" 3)
      http_ok "$code" || nivel_svc=ALERTA
    elif [[ $estado != activating && $estado != reloading ]]; then
      nivel_svc=CRITICO
    fi
    transicao "svc:$svc" "$nivel_svc" \
      "Serviço $svc com problema: systemd=$estado, HTTP=$code" \
      "Serviço $svc normalizado: systemd=$estado, HTTP=$code"

    n=$(systemctl show -p NRestarts --value "$svc" 2>/dev/null); n=${n:-0}
    pid=$(systemctl show -p MainPID --value "$svc" 2>/dev/null)
    if [[ -n ${RESTARTS[$svc]:-} ]] && (( n > RESTARTS[$svc] )); then
      alerta RECUPERADO "systemd reiniciou $svc automaticamente após uma falha (reinícios: ${RESTARTS[$svc]} -> $n, novo PID $pid)"
    fi
    RESTARTS[$svc]=$n
    svc_txt+=" ${svc#heatsafe-}=$estado/$code"
    servicos_json=$(jq -c --arg s "$svc" --arg e "$estado" --arg h "$code" --argjson r "$n" --arg p "$pid" \
      '. + [{servico: $s, estado: $e, http: $h, reinicios: $r, pid: $p}]' <<<"$servicos_json")
  done

  mlog "CPU ${cpu}% | MEM ${mem}% (${mem_usado}/${mem_total} MB) | DISCO${discos_txt} | LOAD $load |${svc_txt:- sem serviços de app}"

  # status.json (para a página de status e para o healthcheck)
  local ultimos tmp
  ultimos=$(tail -n 10 "$ALERT_LOG" 2>/dev/null | jq -R . | jq -sc 'reverse')
  tmp="$STATUS_JSON.tmp"
  jq -n \
    --arg host "$(hostname)" --arg ts "$(date --iso-8601=seconds)" --arg load "$load" \
    --argjson cpu "$cpu" --argjson mem "$mem" --argjson mu "$mem_usado" --argjson mt "$mem_total" \
    --argjson discos "$discos_json" --argjson servicos "$servicos_json" \
    --argjson alertas "${ultimos:-[]}" \
    --argjson lim "$(jq -cn --argjson a "$CPU_WARN" --argjson b "$CPU_CRIT" --argjson c "$MEM_WARN" \
                      --argjson d "$MEM_CRIT" --argjson e "$DISK_WARN" --argjson f "$DISK_CRIT" \
                      '{cpu:[$a,$b], mem:[$c,$d], disco:[$e,$f]}')" \
    --arg niveis "$(for k in "${!NIVEL[@]}"; do [[ ${NIVEL[$k]} != OK ]] && echo "$k=${NIVEL[$k]}"; done | paste -sd, -)" \
    '{host:$host, atualizado:$ts, cpu_pct:$cpu, mem_pct:$mem, mem_usado_mb:$mu, mem_total_mb:$mt,
      load:$load, discos:$discos, servicos:$servicos, limites:$lim,
      alertas_ativos:($niveis|split(",")|map(select(length>0))), ultimos_alertas:$alertas}' \
    > "$tmp" 2>/dev/null && mv -f "$tmp" "$STATUS_JSON"

  touch "$HEARTBEAT"
}

encerrar() {
  mlog "Monitor encerrado (sinal $1 recebido)"
  exit 0
}

main() {
  mkdir -p "$STATE_DIR" 2>/dev/null
  touch "$MON_LOG" "$ALERT_LOG" 2>/dev/null
  if [[ ${1:-} == --uma-vez ]]; then
    ler_cpu; CPU_TOTAL_ANT=$CPU_TOTAL; CPU_IDLE_ANT=$CPU_IDLE; sleep 1
    MON_CPU_SUSTAIN=1
    verificar
    exit 0
  fi
  trap 'encerrar TERM' TERM
  trap 'encerrar INT' INT
  local n
  n=$(systemctl show -p NRestarts --value heatsafe-monitor 2>/dev/null)
  mlog "Monitor iniciado (PID $$, intervalo ${MON_INTERVAL}s) | limites CPU ${CPU_WARN}/${CPU_CRIT}% MEM ${MEM_WARN}/${MEM_CRIT}% DISCO ${DISK_WARN}/${DISK_CRIT}%"
  if [[ ${n:-0} -gt 0 ]]; then
    alerta RECUPERADO "monitor reiniciado pelo systemd após falha (reinícios desde o boot: $n)"
  fi
  ler_cpu; CPU_TOTAL_ANT=$CPU_TOTAL; CPU_IDLE_ANT=$CPU_IDLE
  sleep 1
  while true; do
    verificar
    sleep "$MON_INTERVAL" &
    wait $!
  done
}

main "$@"
