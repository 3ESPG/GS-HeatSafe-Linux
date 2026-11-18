#!/usr/bin/env bash
# =============================================================================
# HeatSafe · teste_falha.sh  (entregável: Teste de falha)
#
# Provoca falhas de propósito e mostra, ao vivo, o sistema se recuperando.
# Tudo fica registrado em /var/log/heatsafe/teste_falha.log e auditoria.log.
#
# Uso: sudo ./teste_falha.sh <teste>
#   api        kill -9 na API         -> systemd reinicia (Restart=always)
#   previsao   kill -9 na previsão    -> systemd reinicia
#   monitor    kill -9 no monitor     -> systemd reinicia
#   travar     congela o monitor (SIGSTOP) -> healthcheck detecta pelo heartbeat e reinicia
#   parar      "systemctl stop" na API -> healthcheck (timer) sobe de volta
#   cpu        CPU a 100%             -> alerta de CPU   (e RESOLVIDO depois)
#   memoria    consome memória        -> alerta de memória
#   disco      enche o disco          -> alerta de disco (o arquivo é apagado no final)
#   todos      todos acima, em sequência
# =============================================================================
set -Eeuo pipefail
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/common.sh"

ALERT_LOG="$HS_LOG/alertas.log"
ARQ_DISCO="/var/tmp/heatsafe-teste-disco.img"

ms() { date +%s%3N; }

# Mostra (uma vez só) as linhas novas de alertas.log até aparecer PADRAO ou estourar o tempo.
# ALERT_INI = nº de linhas do arquivo no início do teste; ALERT_VISTAS = já impressas.
marcar_inicio() { ALERT_INI=$(wc -l < "$ALERT_LOG"); ALERT_VISTAS=$ALERT_INI; }
mostrar_novos() {
  local total linha
  total=$(wc -l < "$ALERT_LOG")
  (( total > ALERT_VISTAS )) || return 0
  while IFS= read -r linha; do
    printf '      %s%s%s\n' "$C_YELLOW" "$linha" "$C_RST" >&"${HS_TTY_FD:-1}"
    echo "      $linha" >> "$HS_EXEC_LOG"
  done < <(sed -n "$((ALERT_VISTAS + 1)),${total}p" "$ALERT_LOG")
  ALERT_VISTAS=$total
}
esperar_alerta() {  # esperar_alerta PADRAO TIMEOUT -> 0 se apareceu
  local padrao=$1 limite=$2 i
  for ((i = 0; i <= limite; i++)); do
    mostrar_novos
    sed -n "$((ALERT_INI + 1)),\$p" "$ALERT_LOG" | grep -qE "$padrao" && return 0
    sleep 1
  done
  return 1
}

evidencias_servico() {
  local svc=$1
  info "Evidência 1 — $HS_LOG/servicos.log:"
  grep "$svc" "$HS_LOG/servicos.log" 2>/dev/null | tail -n 3 | sed 's/^/      /'
  info "Evidência 2 — journal do systemd:"
  journalctl -u "$svc" -n 6 --no-pager -o short-iso 2>/dev/null | sed 's/^/      /'
  if command -v ausearch >/dev/null; then
    info "Evidência 3 — auditd (quem enviou o SIGKILL):"
    ausearch -k heatsafe_kill9 -i -ts recent 2>/dev/null | grep -E '^type=SYSCALL' | tail -n 1 \
      | grep -oE '(^| )(auid|uid|comm|exe)=[^ ]+' | sed 's/^ //' | paste -sd' ' | sed 's/^/      /' || true
  fi
}

# ---------- kill -9 num serviço ----------
teste_kill() {
  local svc=$1 url=${2:-}
  if ! servico_existe "$svc" || ! systemctl is-active --quiet "$svc"; then
    warn "$svc não está instalado/ativo; pulando"
    return 0
  fi
  step "Teste de falha: kill -9 em $svc"
  local pid0 n0 t0 pid n estado code dt i
  pid0=$(systemctl show -p MainPID --value "$svc")
  n0=$(systemctl show -p NRestarts --value "$svc")
  info "ANTES: $svc ativo | PID $pid0 | reinícios automáticos: $n0${url:+ | $url -> HTTP $(http_code "$url")}"
  run "Simulando um crash: kill -9 $pid0 (SIGKILL não pode ser tratado pelo processo)" kill -9 "$pid0"
  t0=$(ms)
  for ((i = 0; i < 120; i++)); do
    sleep 0.5
    estado=$(systemctl is-active "$svc" 2>/dev/null || true)
    pid=$(systemctl show -p MainPID --value "$svc")
    code="   "; [[ -n $url ]] && code=$(http_code "$url" 1)
    dt=$(( $(ms) - t0 ))
    printf '      t+%2d.%01ds  systemd=%-12s PID=%-7s %s\n' $((dt / 1000)) $(((dt % 1000) / 100)) "$estado" "$pid" \
      "${url:+HTTP $code}" | tee -a "$HS_EXEC_LOG" >&"${HS_TTY_FD:-1}"
    if [[ $estado == active && $pid != 0 && $pid != "$pid0" ]] && { [[ -z $url ]] || http_ok "$code"; }; then
      break
    fi
  done
  n=$(systemctl show -p NRestarts --value "$svc")
  dt=$(( $(ms) - t0 ))
  if [[ $pid != "$pid0" && $estado == active ]]; then
    ok "RECUPERADO em $((dt / 1000)).$(((dt % 1000) / 100))s | PID $pid0 -> $pid | reinícios automáticos $n0 -> $n"
    audit TESTE_FALHA "kill -9 $svc: recuperado em ${dt}ms (PID $pid0->$pid, NRestarts $n0->$n)"
  else
    error "$svc não se recuperou em 60s"
    audit TESTE_FALHA "kill -9 $svc: NAO recuperou"
  fi
  sleep 1
  evidencias_servico "$svc"
}

# ---------- monitor travado (SIGSTOP) ----------
teste_travar() {
  local svc=heatsafe-monitor hb="$HS_DATA/monitor/heartbeat"
  servico_existe "$svc" || { warn "monitor não instalado"; return 0; }
  step "Teste de falha: monitor TRAVADO (processo vivo, mas parado)"
  local pid0 idade
  pid0=$(systemctl show -p MainPID --value "$svc")
  run "Congelando o monitor: kill -STOP $pid0" kill -STOP "$pid0"
  info "O systemd ainda acha que está tudo bem: $(systemctl is-active $svc). Só o heartbeat revela o problema."
  while :; do
    idade=$(( $(date +%s) - $(stat -c %Y "$hb") ))
    printf '\r      heartbeat parado há %3ss (limite %ss)' "$idade" "$HEARTBEAT_MAX_AGE" >&"${HS_TTY_FD:-1}"
    (( idade > HEARTBEAT_MAX_AGE )) && break
    sleep 1
  done
  echo >&"${HS_TTY_FD:-1}"
  if [[ ${ESPERAR_TIMER:-0} == 1 ]]; then
    info "Esperando o heatsafe-healthcheck.timer (até 60s)..."
    local i; for ((i = 0; i < 70; i++)); do
      [[ $(systemctl show -p MainPID --value $svc) != "$pid0" ]] && break; sleep 1
    done
  else
    info "Disparando o healthcheck agora (o timer faz isso sozinho a cada 1 min; use ESPERAR_TIMER=1 para esperar)"
    systemctl start heatsafe-healthcheck.service
  fi
  sleep 2
  ok "Monitor: PID $pid0 -> $(systemctl show -p MainPID --value $svc) | $(systemctl is-active $svc)"
  info "Evidência — $HS_LOG/healthcheck.log:"
  tail -n 4 "$HS_LOG/healthcheck.log" | sed 's/^/      /'
  audit TESTE_FALHA "monitor travado (SIGSTOP) -> healthcheck reiniciou"
}

# ---------- parada manual -> healthcheck sobe de volta ----------
teste_parar() {
  local svc=heatsafe-api
  servico_existe "$svc" || svc=heatsafe-previsao
  servico_existe "$svc" || { warn "nenhum serviço de app instalado"; return 0; }
  step "Teste de falha: '$svc' parado com systemctl stop (o Restart=always NÃO age numa parada manual)"
  run "Parando $svc" systemctl stop "$svc"
  info "Estado: $(systemctl is-active "$svc" || true)"
  info "Disparando o healthcheck (o timer faria isso em até 1 min)"
  systemctl start heatsafe-healthcheck.service
  ok "Estado depois do healthcheck: $(systemctl is-active "$svc") (PID $(systemctl show -p MainPID --value "$svc"))"
  tail -n 3 "$HS_LOG/healthcheck.log" | sed 's/^/      /'
  audit TESTE_FALHA "systemctl stop $svc -> healthcheck religou"
}

# ---------- CPU ----------
teste_cpu() {
  local dur=$(( MON_INTERVAL * (MON_CPU_SUSTAIN + 3) + 10 )) pids=()
  step "Teste de carga: CPU a 100% por ${dur}s"
  marcar_inicio
  if command -v stress-ng >/dev/null; then
    # nice 19 = prioridade mínima: a CPU vai a 100%, mas o monitor ainda consegue rodar e alertar
    info "nice -n 19 stress-ng --cpu $(nproc) --timeout ${dur}s"
    nice -n 19 stress-ng --cpu "$(nproc)" --cpu-load 100 --timeout "${dur}s" --quiet & pids+=($!)
  else
    info "stress-ng ausente; usando $(nproc) laços infinitos em Bash"
    local c; for ((c = 0; c < $(nproc); c++)); do nice -n 19 timeout "$dur" bash -c 'while :; do :; done' & pids+=($!); done
  fi
  audit TESTE_CARGA "CPU 100% por ${dur}s"
  esperar_alerta '\[CRITICO\] Uso de CPU' "$dur" \
    || info "A CPU não chegou ao nível crítico (${CPU_CRIT}%) nesta máquina; veja acima o nível atingido"
  info "Encerrando a carga..."
  kill "${pids[@]}" 2>/dev/null || true; pkill -x stress-ng 2>/dev/null || true; wait "${pids[@]}" 2>/dev/null || true
  esperar_alerta 'RESOLVIDO\] Uso de CPU' $((MON_INTERVAL * 2 + 10)) || warn "Alerta de CPU ainda não foi resolvido"
}

# ---------- Memória ----------
teste_memoria() {
  local total usado disp alvo_pct alvo_k need dur=$(( MON_INTERVAL * 3 + 5 )) pid
  read -r total disp < <(awk '/^MemTotal:/{t=$2} /^MemAvailable:/{a=$2} END{print t, a}' /proc/meminfo)
  usado=$((total - disp))
  alvo_pct=$(( MEM_CRIT + 2 ))
  alvo_k=$(( total * alvo_pct / 100 ))
  need=$(( alvo_k - usado ))
  # nunca deixa menos de 200 MB disponíveis (evita o OOM killer derrubar a API de verdade)
  if (( disp - need < 204800 )); then
    need=$(( disp - 204800 ))
    alvo_pct=$(( (usado + need) * 100 / total ))
    warn "Limitando o consumo para manter 200 MB livres (vai a ~${alvo_pct}%)"
  fi
  (( need > 0 )) || { warn "Memória já acima do alvo; nada a alocar"; return 0; }
  step "Teste de carga: memória até ~${alvo_pct}% (alocando $((need / 1024)) MB por ${dur}s)"
  marcar_inicio
  python3 -c "import time,sys; b=bytearray(b'\x01')*int(sys.argv[1]); time.sleep(int(sys.argv[2]))" \
    $((need * 1024)) "$dur" &
  pid=$!
  audit TESTE_CARGA "memória +$((need / 1024)) MB por ${dur}s"
  esperar_alerta '\[CRITICO\] Uso de memória' "$dur" \
    || info "A memória não chegou ao nível crítico (${MEM_CRIT}%); veja acima o nível atingido"
  kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true
  info "Memória liberada"
  esperar_alerta 'RESOLVIDO\] Uso de memória' $((MON_INTERVAL * 2 + 10)) || warn "Alerta de memória ainda não foi resolvido"
}

# ---------- Disco ----------
limpar_disco() { rm -f "$ARQ_DISCO"; }
teste_disco() {
  local usado livre alvo_pct need
  read -r usado livre < <(df -Pk "$(dirname "$ARQ_DISCO")" | awk 'NR==2{print $3, $4}')
  alvo_pct=$(( DISK_CRIT + 2 ))
  need=$(( (usado + livre) * alvo_pct / 100 - usado + 1024 ))
  if (( livre - need < 307200 )); then
    need=$(( livre - 307200 ))
    warn "Limitando para manter 300 MB livres"
  fi
  (( need > 0 )) || { warn "Disco já acima do alvo ou sem espaço para o teste"; return 0; }
  step "Teste de falha: disco cheio — criando $ARQ_DISCO com $((need / 1024)) MB (alvo ~${alvo_pct}%)"
  marcar_inicio
  run "Ocupando espaço (fallocate)" fallocate -l "${need}K" "$ARQ_DISCO"
  df -h "$(dirname "$ARQ_DISCO")" | sed 's/^/      /'
  esperar_alerta '\[CRITICO\] Uso de disco' $((MON_INTERVAL * 2 + 10)) \
    || warn "O alerta crítico de disco não apareceu (o monitor está rodando?)"
  run "Liberando o espaço" rm -f "$ARQ_DISCO"
  esperar_alerta 'RESOLVIDO\] Uso de disco' $((MON_INTERVAL * 2 + 10)) || warn "Alerta de disco ainda não foi resolvido"
}

uso() {
  sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
  exit 1
}

main() {
  [[ $# -ge 1 ]] || uso
  hs_init "$@"
  trap 'rc=$?; limpar_disco; _hs_on_exit $rc' EXIT
  require_root
  case $1 in
    api)      teste_kill heatsafe-api "http://api.$HS_DOMAIN$API_HEALTH_PATH" ;;
    previsao) teste_kill heatsafe-previsao "http://previsao.$HS_DOMAIN$PREVISAO_HEALTH_PATH" ;;
    monitor)  teste_kill heatsafe-monitor ;;
    travar)   teste_travar ;;
    parar)    teste_parar ;;
    cpu)      teste_cpu ;;
    memoria)  teste_memoria ;;
    disco)    teste_disco ;;
    todos)
      teste_kill heatsafe-api "http://api.$HS_DOMAIN$API_HEALTH_PATH"
      teste_kill heatsafe-previsao "http://previsao.$HS_DOMAIN$PREVISAO_HEALTH_PATH"
      teste_kill heatsafe-monitor
      teste_travar; teste_parar; teste_cpu; teste_memoria; teste_disco ;;
    *) uso ;;
  esac
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
