#!/usr/bin/env bash
# =============================================================================
# HeatSafe · coletar_evidencias.sh — junta as evidências técnicas para o GitHub
#
# Cria infra/evidencias/<data-hora>/ com a saída dos principais comandos
# (rede, DNS, firewall, serviços, units, logs, auditd) para versionar no repo.
# Segredos do .env são mascarados.
# Uso: sudo ./coletar_evidencias.sh   (rode depois do provisionamento e dos testes)
# =============================================================================
set -Eeuo pipefail
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/common.sh"

main() {
  hs_init "$@"
  require_root
  local destino="${1:-$HS_INFRA_DIR/evidencias}/$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$destino"
  step "Coletando evidências em $destino"

  salvar() {  # salvar ARQUIVO "titulo" comando...
    local arq=$1 tit=$2; shift 2
    { echo "### $tit"; echo "\$ $*"; "$@" 2>&1 || true; echo; } >> "$destino/$arq"
  }

  salvar 01-sistema.txt   "Identidade"          hostnamectl
  salvar 01-sistema.txt   "Data, fuso e NTP"    timedatectl
  salvar 01-sistema.txt   "Usuário de serviço"  id "$HS_USER"
  salvar 01-sistema.txt   "Pastas"              ls -ld "$HS_BASE" "$HS_ETC" "$HS_DATA" "$HS_LOG" "$HS_STATUS_DIR"

  salvar 02-rede.txt      "Interfaces"          ip -br addr
  salvar 02-rede.txt      "Rotas"               ip route
  salvar 02-rede.txt      "Netplan HeatSafe"    cat /etc/netplan/60-heatsafe.yaml
  salvar 02-rede.txt      "DNS (resolved)"      resolvectl status
  salvar 02-rede.txt      "Portas em escuta"    ss -tlnp

  salvar 03-dns-local.txt "/etc/hosts"          cat /etc/hosts
  local n
  for n in $HS_HOSTNAME $HS_DNS_NAMES; do salvar 03-dns-local.txt "Resolução de $n" getent hosts "$n"; done

  salvar 04-firewall.txt  "ufw"                 ufw status verbose

  salvar 05-servicos.txt  "Serviços HeatSafe"   systemctl status --no-pager -l heatsafe-api heatsafe-previsao heatsafe-monitor heatsafe-healthcheck.timer nginx mysql
  salvar 05-servicos.txt  "Timers"              systemctl list-timers --no-pager 'heatsafe-*'
  salvar 05-servicos.txt  "Reinícios (NRestarts)" systemctl show -p Id -p NRestarts -p Restart -p MainPID heatsafe-api heatsafe-previsao heatsafe-monitor
  local u
  for u in /etc/systemd/system/heatsafe-*; do salvar 06-units-systemd.txt "$u" cat "$u"; done
  salvar 06-units-systemd.txt "nginx" cat /etc/nginx/sites-available/heatsafe.conf

  salvar 07-aplicacao.txt "API (via DNS)"       curl -s -i -m 5 "http://api.$HS_DOMAIN$API_HEALTH_PATH"
  salvar 07-aplicacao.txt "Previsão health (via DNS)" curl -s -i -m 5 "http://previsao.$HS_DOMAIN$PREVISAO_HEALTH_PATH"
  salvar 07-aplicacao.txt "Previsão de amanhã (contrato usado pela API C#)" curl -s -i -m 15 "http://previsao.$HS_DOMAIN/previsao/amanha?estacao=A701"
  salvar 07-aplicacao.txt "Status do monitor"   curl -s -m 5 "http://monitor.$HS_DOMAIN/status.json"
  local envf
  for envf in "$HS_ENV_API" "$HS_ENV_PREVISAO"; do
    { echo "### $envf (segredos mascarados)"
      sed -E 's/^((Jwt__SigningKey|DB_PASSWORD)=).*/\1"********"/' "$envf" 2>/dev/null; echo
    } >> "$destino/07-aplicacao.txt"
  done

  local f
  for f in auditoria alertas servicos healthcheck monitor teste_falha teste_ponta_a_ponta provision_infra provision_app provision_monitor; do
    [[ -f $HS_LOG/$f.log ]] && tail -n 300 "$HS_LOG/$f.log" | sed -E 's/\x1b\[[0-9;]*m//g' > "$destino/log-$f.log"
  done
  if command -v ausearch >/dev/null; then
    for n in heatsafe_kill9 heatsafe_config heatsafe_dns heatsafe_rede heatsafe_systemd; do
      salvar 08-auditd.txt "auditd chave $n" bash -c "ausearch -k $n -i 2>/dev/null | tail -n 40"
    done
  fi
  salvar 09-journal.txt "journal HeatSafe (últimas 150 linhas)" \
    journalctl --no-pager -n 150 -u heatsafe-api -u heatsafe-previsao -u heatsafe-monitor -u heatsafe-healthcheck

  chown -R "${SUDO_USER:-root}": "$destino" 2>/dev/null || true
  ok "Evidências salvas ($(ls "$destino" | wc -l) arquivos):"
  ls -1 "$destino" | sed 's/^/      /'
  info "Para versionar: git add infra/evidencias && git commit -m 'evidencias da infra'"
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
