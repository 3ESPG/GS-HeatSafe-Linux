#!/usr/bin/env bash
# =============================================================================
# HeatSafe · hooks/evento_servico.sh
# Chamado pelo systemd (ExecStartPost / ExecStopPost) de cada serviço HeatSafe.
# Registra em /var/log/heatsafe/servicos.log quando um serviço sobe ou cai e por quê.
# No ExecStopPost o systemd fornece: SERVICE_RESULT, EXIT_CODE, EXIT_STATUS.
#   kill -9  -> SERVICE_RESULT=signal EXIT_CODE=killed EXIT_STATUS=KILL
# Uso (pelo systemd): evento_servico.sh <unit> iniciado|parado
# =============================================================================
unit=${1:-?}
evento=${2:-?}
LOG_DIR=/var/log/heatsafe
LOG="$LOG_DIR/servicos.log"
ts=$(date --iso-8601=seconds)

case $evento in
  iniciado)
    pid=$(systemctl show -p MainPID --value "$unit" 2>/dev/null)
    n=$(systemctl show -p NRestarts --value "$unit" 2>/dev/null)
    msg="INICIADO | pid=${pid:-?} | reinicios_automaticos=${n:-0}"
    ;;
  parado)
    resultado=${SERVICE_RESULT:-?}
    detalhe="resultado=$resultado codigo=${EXIT_CODE:-?} status=${EXIT_STATUS:-?}"
    if [[ $resultado == success ]]; then
      msg="PARADO | $detalhe (parada normal)"
    else
      msg="FALHA | $detalhe -> systemd vai reiniciar (Restart=always)"
    fi
    ;;
  *)
    msg="EVENTO $evento"
    ;;
esac

mkdir -p "$LOG_DIR"
echo "$ts | $unit | $msg" >> "$LOG"
chgrp heatsafe "$LOG" 2>/dev/null; chmod 660 "$LOG" 2>/dev/null
logger -t heatsafe-servicos -- "$unit $msg" 2>/dev/null
exit 0
