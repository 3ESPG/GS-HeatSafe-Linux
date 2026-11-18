#!/usr/bin/env bash
# =============================================================================
# HeatSafe · healthcheck.sh  (critério: monitoramento como serviço tolerante a falhas)
#
# 2ª camada de tolerância a falhas. Roda como root a cada 1 minuto pelo
# heatsafe-healthcheck.timer e CORRIGE o que o Restart=always sozinho não cobre:
#   - serviço parado/falho (ex.: alguém deu "systemctl stop" ou o systemd desistiu)
#   - monitor TRAVADO: o processo existe, mas parou de trabalhar (heartbeat velho)
#   - serviço "active" mas sem responder HTTP por 2 verificações seguidas
# Tudo vai para /var/log/heatsafe/healthcheck.log e auditoria.log.
#
# Manutenção planejada: crie /etc/heatsafe/manutencao para pausar a autocorreção.
# Uso: sudo ./healthcheck.sh   (ou: systemctl start heatsafe-healthcheck.service)
# =============================================================================
set -uo pipefail
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/common.sh"
HS_SCRIPT=healthcheck.sh

HC_LOG="$HS_LOG/healthcheck.log"
HEARTBEAT="$HS_DATA/monitor/heartbeat"
FALHAS_DIR="$HS_DATA/monitor/healthcheck"
ACOES=0

hc() {
  local linha; linha="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
  echo "$linha"
  echo "$linha" >> "$HC_LOG"
}

corrigir() {  # corrigir SERVICO MOTIVO
  local svc=$1 motivo=$2
  hc "AUTOCORRECAO | $svc | $motivo -> reiniciando"
  audit AUTOCORRECAO "$svc: $motivo"
  logger -p user.warning -t heatsafe-healthcheck -- "$svc: $motivo -> reiniciando" 2>/dev/null
  systemctl reset-failed "$svc" 2>/dev/null
  systemctl restart "$svc"
  sleep 3
  hc "AUTOCORRECAO | $svc | agora: $(systemctl is-active "$svc") (PID $(systemctl show -p MainPID --value "$svc"))"
  ACOES=$((ACOES + 1))
}

[[ $EUID -eq 0 ]] || { echo "Rode como root (sudo)"; exit 1; }
mkdir -p "$FALHAS_DIR"
touch "$HC_LOG"; chgrp "$HS_GROUP" "$HC_LOG" 2>/dev/null; chmod 660 "$HC_LOG"

if [[ -f $HS_ETC/manutencao ]]; then
  hc "MANUTENCAO | $HS_ETC/manutencao existe — autocorreção pausada"
  exit 0
fi

resumo=()
for svc in "${HS_SERVICOS[@]}"; do
  servico_existe "$svc" || continue
  [[ $(systemctl is-enabled "$svc" 2>/dev/null) == enabled ]] || continue
  estado=$(systemctl is-active "$svc" 2>/dev/null)

  # 1) Serviço que deveria estar rodando e não está
  if [[ $estado != active && $estado != activating && $estado != reloading ]]; then
    corrigir "$svc" "estava '$estado' (deveria estar active)"
    resumo+=("${svc#heatsafe-}=reiniciado")
    continue
  fi

  # 2) Monitor travado: processo vivo, mas sem heartbeat recente
  if [[ $svc == heatsafe-monitor ]]; then
    idade=999999
    [[ -f $HEARTBEAT ]] && idade=$(( $(date +%s) - $(stat -c %Y "$HEARTBEAT") ))
    if (( idade > HEARTBEAT_MAX_AGE )); then
      hc "TRAVADO | $svc | último heartbeat há ${idade}s (limite ${HEARTBEAT_MAX_AGE}s)"
      systemctl kill -s SIGKILL "$svc" 2>/dev/null
      sleep 1
      corrigir "$svc" "processo travado (sem heartbeat há ${idade}s)"
      resumo+=("monitor=destravado")
    else
      resumo+=("monitor=ok(heartbeat ${idade}s)")
    fi
    continue
  fi

  # 3) Ativo no systemd mas sem responder HTTP (2 verificações seguidas)
  case $svc in
    heatsafe-api)      url="http://127.0.0.1:$API_PORT$API_HEALTH_PATH" ;;
    heatsafe-previsao) url="http://127.0.0.1:$PREVISAO_PORT$PREVISAO_HEALTH_PATH" ;;
  esac
  code=$(http_code "$url" 5)
  arq="$FALHAS_DIR/${svc}.falhas"
  if http_ok "$code"; then
    rm -f "$arq"
    resumo+=("${svc#heatsafe-}=ok(HTTP $code)")
  else
    falhas=$(( $(cat "$arq" 2>/dev/null || echo 0) + 1 ))
    echo "$falhas" > "$arq"
    hc "SEM_RESPOSTA | $svc | HTTP $code (falha $falhas de 2)"
    if (( falhas >= 2 )); then
      corrigir "$svc" "ativo mas sem responder HTTP há $falhas verificações"
      rm -f "$arq"
      resumo+=("${svc#heatsafe-}=reiniciado")
    else
      resumo+=("${svc#heatsafe-}=sem_resposta($falhas)")
    fi
  fi
done

hc "VERIFICACAO | ${resumo[*]:-nenhum serviço HeatSafe habilitado} | ações: $ACOES"
exit 0
