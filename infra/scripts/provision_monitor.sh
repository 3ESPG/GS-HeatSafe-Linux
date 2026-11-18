#!/usr/bin/env bash
# =============================================================================
# HeatSafe · provision_monitor.sh  (critério: monitoramento como serviço
#                                    tolerante a falhas)
#
# Instala o monitoramento como serviços do systemd:
#   heatsafe-monitor.service     -> monitor.sh rodando sempre (Restart=always)
#   heatsafe-healthcheck.timer   -> a cada 1 min roda healthcheck.sh (autocorreção)
# e confere se o monitor está gerando heartbeat, logs e o status.json.
#
# Uso: sudo ./provision_monitor.sh   (depois do provision_infra.sh)
# =============================================================================
set -Eeuo pipefail
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/common.sh"

main() {
  hs_init "$@"

  step "Checagens"
  require_root
  id "$HS_USER" >/dev/null 2>&1 || die "Usuário $HS_USER não existe. Rode antes: sudo ./provision_infra.sh"
  command -v jq >/dev/null || apt_install jq
  install_infra_copy
  install -d -o "$HS_USER" -g "$HS_GROUP" -m 0750 "$HS_DATA/monitor"
  install -d -o "$HS_USER" -g "$HS_GROUP" -m 0755 "$HS_STATUS_DIR"
  ok "Pré-requisitos ok"

  step "Teste rápido do monitor (uma leitura, como usuário $HS_USER)"
  runuser -u "$HS_USER" -- "$HS_INFRA_INSTALL/scripts/monitor.sh" --uma-vez | sed 's/^/      /'

  step "Instalando as units do systemd"
  local u
  for u in heatsafe-monitor.service heatsafe-healthcheck.service heatsafe-healthcheck.timer; do
    render_template "$HS_INFRA_DIR/systemd/$u" "/etc/systemd/system/$u"
    ok "/etc/systemd/system/$u"
  done
  if command -v systemd-analyze >/dev/null; then
    systemd-analyze verify /etc/systemd/system/heatsafe-monitor.service \
      /etc/systemd/system/heatsafe-healthcheck.{service,timer} 2>&1 | grep -v '^$' | sed 's/^/      /' || true
  fi
  run "Recarregando o systemd" systemctl daemon-reload

  step "Ligando o monitor e o timer de healthcheck"
  run "Habilitando no boot" systemctl enable heatsafe-monitor.service heatsafe-healthcheck.timer
  run "(Re)iniciando o monitor" systemctl restart heatsafe-monitor.service
  run "Iniciando o timer" systemctl restart heatsafe-healthcheck.timer

  step "Verificando"
  local i
  for ((i = 0; i < 20; i++)); do
    [[ -f $HS_DATA/monitor/heartbeat && $(( $(date +%s) - $(stat -c %Y "$HS_DATA/monitor/heartbeat") )) -lt 10 ]] && break
    sleep 1
  done
  systemctl is-active --quiet heatsafe-monitor || die "heatsafe-monitor não está ativo (journalctl -u heatsafe-monitor)"
  ok "heatsafe-monitor ativo (PID $(systemctl show -p MainPID --value heatsafe-monitor), Restart=$(systemctl show -p Restart --value heatsafe-monitor))"
  ok "Heartbeat: $(stat -c %y "$HS_DATA/monitor/heartbeat" 2>/dev/null | cut -d. -f1)"
  ok "Última leitura: $(tail -n 1 "$HS_LOG/monitor.log")"
  systemctl list-timers heatsafe-healthcheck.timer --no-pager | sed 's/^/      /'
  run "Primeira execução do healthcheck" systemctl start heatsafe-healthcheck.service
  ok "Healthcheck: $(tail -n 1 "$HS_LOG/healthcheck.log")"
  local code
  code=$(http_code "http://monitor.$HS_DOMAIN/status.json")
  if http_ok "$code"; then ok "Página de status: http://monitor.$HS_DOMAIN (status.json HTTP $code)"
  else warn "status.json via nginx respondeu HTTP $code (o nginx é configurado pelo provision_app.sh)"; fi

  step "Resumo do monitoramento"
  printf '      %-20s %s\n' \
    "Intervalo"     "${MON_INTERVAL}s" \
    "Limites"       "CPU ${CPU_WARN}/${CPU_CRIT}% | MEM ${MEM_WARN}/${MEM_CRIT}% | DISCO ${DISK_WARN}/${DISK_CRIT}% (alerta/crítico)" \
    "Alertas"       "$HS_LOG/alertas.log  (e journalctl -t heatsafe-monitor)" \
    "Leituras"      "$HS_LOG/monitor.log" \
    "Autocorreção"  "$HS_LOG/healthcheck.log (timer a cada 1 min)" \
    "Webhook"       "${ALERT_WEBHOOK_URL:-não configurado}"
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
