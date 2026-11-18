#!/usr/bin/env bash
# =============================================================================
# HeatSafe · status.sh — painel do servidor no terminal (bom para o vídeo)
# Mostra: identidade e rede, DNS local, serviços, endpoints, recursos e
# últimos alertas/eventos. Não altera nada.
# Uso: ./status.sh        (com sudo mostra também o firewall)
#      watch -c -n 5 ./status.sh   (atualiza a cada 5 s)
# =============================================================================
set -uo pipefail
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/common.sh"

titulo() { printf '\n%s━━ %s %s\n' "$C_CYAN" "$*" "$C_RST"; }
linha()  { printf '  %-22s %s\n' "$1" "$2"; }
cor_estado() {
  case $1 in
    active|OK|ok) printf '%s%s%s' "$C_GREEN" "$1" "$C_RST" ;;
    activating|ALERTA) printf '%s%s%s' "$C_YELLOW" "$1" "$C_RST" ;;
    *) printf '%s%s%s' "$C_RED" "$1" "$C_RST" ;;
  esac
}

printf '%s HeatSafe · status do servidor  %s(%s)%s\n' "$C_BOLD" "$C_DIM" "$(date '+%d/%m/%Y %H:%M:%S')" "$C_RST"

titulo "Sistema e rede"
iface=$(ip -4 route show default | awk '{print $5; exit}')
linha "Hostname" "$(hostname)  (FQDN: $(hostname -f 2>/dev/null))"
linha "SO / kernel" "$(. /etc/os-release; echo "$PRETTY_NAME") / $(uname -r)"
linha "IP" "$(ip -4 -o addr show dev "$iface" scope global 2>/dev/null | awk '{print $4; exit}') em $iface"
linha "Gateway" "$(ip -4 route show default | awk '{print $3; exit}')"
dns=$(resolvectl dns "$iface" 2>/dev/null | cut -d: -f2- | xargs)
[[ -z $dns ]] && dns=$(awk '/^nameserver/{print $2}' /etc/resolv.conf | xargs)
linha "DNS externo" "$dns"
linha "Fuso / NTP" "$(timedatectl show -p Timezone --value 2>/dev/null) / sincronizado=$(timedatectl show -p NTPSynchronized --value 2>/dev/null)"
linha "Uptime" "$(uptime -p)"
if [[ $EUID -eq 0 ]]; then linha "Firewall" "$(ufw status 2>/dev/null | head -1)"; fi

titulo "DNS local (/etc/hosts)"
for n in $HS_DNS_NAMES; do linha "$n" "$(getent hosts "$n" | awk '{print $1; exit}')"; done

titulo "Serviços (systemd)"
for svc in "${HS_SERVICOS[@]}" heatsafe-healthcheck.timer nginx mysql auditd; do
  if servico_existe "$svc"; then
    est=$(systemctl is-active "$svc" 2>/dev/null)
    printf '  %-26s %s  PID=%-7s reinícios=%-3s boot=%s\n' "$svc" "$(cor_estado "$est")" \
      "$(systemctl show -p MainPID --value "$svc")" "$(systemctl show -p NRestarts --value "$svc")" \
      "$(systemctl is-enabled "$svc" 2>/dev/null)"
  else
    printf '  %-26s %snão instalado%s\n' "$svc" "$C_DIM" "$C_RST"
  fi
done

titulo "Endpoints (pelo DNS, via nginx)"
for url in "http://api.$HS_DOMAIN$API_HEALTH_PATH" "http://api.$HS_DOMAIN$API_DOCS_PATH" \
           "http://previsao.$HS_DOMAIN$PREVISAO_HEALTH_PATH" "http://previsao.$HS_DOMAIN$PREVISAO_DOCS_PATH" \
           "http://previsao.$HS_DOMAIN/previsao/amanha?estacao=A701" "http://monitor.$HS_DOMAIN/status.json"; do
  code=$(http_code "$url" 3)
  if http_ok "$code"; then est="${C_GREEN}HTTP $code${C_RST}"; else est="${C_RED}HTTP $code${C_RST}"; fi
  printf '  %-58s %s\n' "$url" "$est"
done
corpo=$(curl -s -m 10 "http://previsao.$HS_DOMAIN/previsao/amanha?estacao=A701" 2>/dev/null | head -c 300)
[[ $corpo == \{* ]] && linha "Previsão de amanhã" "$corpo"

titulo "Recursos"
read -r mem mu mt < <(awk '/^MemTotal:/{t=$2} /^MemAvailable:/{a=$2} END{printf "%d %d %d", (t-a)*100/t, (t-a)/1024, t/1024}' /proc/meminfo)
linha "CPU (load 1/5/15)" "$(cut -d' ' -f1-3 /proc/loadavg)  em $(nproc) CPU(s)"
linha "Memória" "${mem}%  (${mu}/${mt} MB)  limites ${MEM_WARN}/${MEM_CRIT}%"
for m in $DISK_MOUNTS; do df -Ph "$m" | awk -v w="$DISK_WARN" -v c="$DISK_CRIT" 'NR==2{printf "  %-22s %s  (%s livres de %s)  limites %s/%s%%\n", "Disco " $6, $5, $4, $2, w, c}'; done | sort -u

titulo "Últimos alertas ($HS_LOG/alertas.log)"
tail -n 6 "$HS_LOG/alertas.log" 2>/dev/null | sed 's/^/  /' || echo "  (nenhum)"
titulo "Últimos eventos de serviço ($HS_LOG/servicos.log)"
tail -n 4 "$HS_LOG/servicos.log" 2>/dev/null | sed 's/^/  /' || echo "  (nenhum)"
titulo "Última verificação do healthcheck"
tail -n 1 "$HS_LOG/healthcheck.log" 2>/dev/null | sed 's/^/  /' || echo "  (nenhuma)"
echo
