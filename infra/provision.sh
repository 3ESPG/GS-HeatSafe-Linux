#!/usr/bin/env bash
# =============================================================================
# HeatSafe · provision.sh — provisiona TUDO com um comando
#
#   1. scripts/provision_infra.sh    rede, IP, DNS, hostname, usuário, firewall, auditoria
#   2. scripts/provision_app.sh      .NET, Java, MySQL, .env, systemd, nginx
#   3. scripts/provision_monitor.sh  monitor como serviço + timer de autocorreção
#   4. scripts/status.sh             painel final
#
# Uso (dentro da VM, na raiz do repositório):
#   sudo ./infra/provision.sh
#   sudo ./infra/provision.sh infra|app|monitor   (só uma etapa)
# =============================================================================
set -Eeuo pipefail
DIR="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
source "$DIR/scripts/lib/common.sh"

hs_init "$@"
require_root

case ${1:-tudo} in
  infra)   etapas=(provision_infra.sh) ;;
  app)     etapas=(provision_app.sh) ;;
  monitor) etapas=(provision_monitor.sh) ;;
  tudo)    etapas=(provision_infra.sh provision_app.sh provision_monitor.sh) ;;
  *) die "Uso: sudo $0 [tudo|infra|app|monitor]" ;;
esac

info "Provisionamento HeatSafe: ${etapas[*]}"
[[ -t 3 ]] && export HS_COLOR=1   # mantém as cores nos scripts filhos
for e in "${etapas[@]}"; do
  step "Executando $e"
  bash "$DIR/scripts/$e"
done

step "Estado final"
bash "$DIR/scripts/status.sh"
