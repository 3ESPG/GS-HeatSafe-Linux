#!/usr/bin/env bash
# =============================================================================
# HeatSafe · provision_infra.sh  (critério: provisionamento de infra — rede, DNS, IP)
#
# Prepara o servidor Linux para receber o HeatSafe:
#   1. checagens do sistema          6. IP estático (netplan) + DNS externos
#   2. pacotes base                  7. DNS local (api.heatsafe.local etc. em /etc/hosts)
#   3. hostname, fuso e NTP          8. firewall (ufw)
#   4. usuário de serviço + pastas   9. SSH endurecido
#   5. instala os scripts em /opt   10. auditoria do SO (auditd) + rotação de logs
#
# Uso:   sudo ./provision_infra.sh
# Idempotente: pode rodar quantas vezes quiser. Cada execução é registrada em
# /var/log/heatsafe/provision_infra.log e /var/log/heatsafe/auditoria.log
# =============================================================================
set -Eeuo pipefail
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/common.sh"

etapa_checagens() {
  step "Checagens do sistema"
  require_root
  # shellcheck disable=SC1091
  . /etc/os-release
  info "Sistema: $PRETTY_NAME | kernel $(uname -r) | $(nproc) CPU(s) | $(free -m | awk '/^Mem:/{print $2}') MB RAM"
  if [[ $ID != ubuntu && $ID != debian && ${ID_LIKE:-} != *debian* ]]; then
    warn "Scripts feitos para Ubuntu 22.04/24.04 (apt + netplan). Em $ID podem precisar de ajustes."
  fi
  [[ -d /run/systemd/system ]] || die "systemd não está ativo neste sistema"
  ok "Pré-requisitos atendidos"
}

etapa_pacotes() {
  step "Pacotes base"
  apt_install curl ca-certificates git rsync jq ufw auditd dnsutils iproute2 iputils-ping \
              logrotate openssl procps psmisc python3
  # stress-ng é usado só nos testes de falha; se não houver, os testes usam alternativas
  info "Instalando stress-ng (opcional, para os testes de carga)..."
  esperar_apt
  apt-get install -y -q -o DPkg::Lock::Timeout=600 stress-ng >/dev/null 2>&1 && ok "stress-ng instalado (testes de carga)" \
    || warn "stress-ng indisponível; os testes de carga usarão alternativa em Bash/Python"
}

etapa_hostname() {
  step "Hostname, fuso horário e NTP"
  local atual
  atual=$(hostnamectl --static 2>/dev/null || hostname)
  if [[ $atual != "$HS_HOSTNAME" ]]; then
    backup_file /etc/hostname
    run "Hostname: $atual -> $HS_HOSTNAME" hostnamectl set-hostname "$HS_HOSTNAME"
  else
    ok "Hostname já é $HS_HOSTNAME"
  fi
  # Em VMs com cloud-init, impede que ele desfaça hostname e /etc/hosts no próximo boot
  if [[ -d /etc/cloud/cloud.cfg.d ]]; then
    printf '# HeatSafe: hostname e /etc/hosts são gerenciados por provision_infra.sh\npreserve_hostname: true\nmanage_etc_hosts: false\n' \
      > /etc/cloud/cloud.cfg.d/99-heatsafe.cfg
    audit ARQUIVO "cloud-init: preserve_hostname=true, manage_etc_hosts=false"
  fi
  run "Fuso horário: $HS_TIMEZONE" timedatectl set-timezone "$HS_TIMEZONE"
  timedatectl set-ntp true 2>/dev/null && ok "Sincronização de horário (NTP) ligada" \
    || warn "Não foi possível ligar o NTP (timesyncd ausente?)"
}

etapa_usuario() {
  step "Usuário de serviço e estrutura de pastas"
  if ! getent group "$HS_GROUP" >/dev/null; then
    run "Criando grupo $HS_GROUP" groupadd --system "$HS_GROUP"
  fi
  if ! id "$HS_USER" >/dev/null 2>&1; then
    run "Criando usuário de serviço $HS_USER (sem login, sem senha)" \
      useradd --system --gid "$HS_GROUP" --home-dir "$HS_BASE" --no-create-home \
              --shell /usr/sbin/nologin --comment "HeatSafe service account" "$HS_USER"
  else
    ok "Usuário $HS_USER já existe ($(id "$HS_USER"))"
  fi
  local admin=${HS_ADMIN_USER:-${SUDO_USER:-}}
  if [[ -n $admin && $admin != root ]] && id "$admin" >/dev/null 2>&1; then
    run "Adicionando $admin aos grupos $HS_GROUP e adm (leitura dos logs)" usermod -aG "$HS_GROUP,adm" "$admin"
  fi
  # dono:grupo e permissões de cada pasta (princípio do menor privilégio)
  install -d -o root      -g "$HS_GROUP" -m 0750 "$HS_BASE" "$HS_ETC"
  install -d -o "$HS_USER" -g "$HS_GROUP" -m 0750 "$HS_DATA" "$HS_DATA/api" "$HS_DATA/previsao" "$HS_DATA/monitor"
  install -d -o root      -g "$HS_GROUP" -m 2770 "$HS_LOG"
  install -d -o "$HS_USER" -g "$HS_GROUP" -m 0755 "$HS_STATUS_DIR"
  install -d -o root      -g root        -m 0700 "$HS_BACKUP"
  chgrp "$HS_GROUP" "$HS_LOG"/*.log 2>/dev/null || true
  audit PERMISSOES "pastas criadas: $HS_BASE $HS_ETC $HS_DATA $HS_LOG $HS_STATUS_DIR $HS_BACKUP"
  ok "Pastas prontas:"
  ls -ld "$HS_BASE" "$HS_ETC" "$HS_DATA" "$HS_LOG" "$HS_STATUS_DIR" | sed 's/^/      /'
}

etapa_scripts() {
  step "Instalando os scripts em $HS_INFRA_INSTALL"
  install_infra_copy
  ok "Scripts instalados (usados pelos serviços systemd)"
}

# ---------- Rede ----------
detectar_rede() {
  NET_IFACE=${NET_IFACE:-$(ip -4 route show default | awk '{print $5; exit}')}
  [[ -n $NET_IFACE ]] || die "Interface com rota padrão não encontrada. Defina NET_IFACE em config/heatsafe.conf"
  ATUAL_IP=$(ip -4 -o addr show dev "$NET_IFACE" scope global | awk '{print $4; exit}')
  ATUAL_GW=$(ip -4 route show default dev "$NET_IFACE" | awk '{print $3; exit}')
  ALVO_IP=${NET_IP:-$ATUAL_IP}
  ALVO_GW=${NET_GATEWAY:-$ATUAL_GW}
  [[ $ALVO_IP == */* ]] || die "IP '$ALVO_IP' precisa estar no formato CIDR (ex.: 192.168.56.10/24)"
}

gerar_netplan() {
  local dns renderer=networkd
  dns=$(echo "$NET_DNS" | sed 's/ //g; s/,/, /g')
  systemctl is-active --quiet NetworkManager 2>/dev/null && renderer=NetworkManager
  echo "# Gerado por HeatSafe provision_infra.sh — não edite à mão (edite config/heatsafe.conf)"
  echo "network:"
  echo "  version: 2"
  echo "  renderer: $renderer"
  echo "  ethernets:"
  echo "    $NET_IFACE:"
  if [[ $NET_MODE == static ]]; then
    echo "      dhcp4: false"
    echo "      dhcp6: false"
    echo "      addresses: [$ALVO_IP]"
    echo "      routes:"
    echo "        - to: default"
    echo "          via: $ALVO_GW"
  else
    echo "      dhcp4: true"
    echo "      dhcp4-overrides:"
    echo "        use-dns: false"
  fi
  echo "      nameservers:"
  echo "        search: [$HS_DOMAIN]"
  echo "        addresses: [$dns]"
}

etapa_rede() {
  step "Rede: IP ($NET_MODE) e servidores DNS"
  detectar_rede
  info "Interface: $NET_IFACE | IP atual: ${ATUAL_IP:-nenhum} | gateway atual: ${ATUAL_GW:-nenhum}"
  if ! command -v netplan >/dev/null; then
    warn "netplan não encontrado; mantendo a configuração de rede atual (IP $ATUAL_IP)"
    return 0
  fi
  local yaml=/etc/netplan/60-heatsafe.yaml novo
  novo=$(gerar_netplan)
  if [[ -f $yaml && "$(cat "$yaml")" == "$novo" ]]; then
    ok "Netplan já configurado ($yaml)"
  else
    [[ -f $yaml ]] && backup_file "$yaml"
    local f
    for f in /etc/netplan/*.yaml; do
      [[ $f == "$yaml" || ! -f $f ]] && continue
      backup_file "$f"
      if grep -q "addresses:" "$f" && grep -q "$NET_IFACE" "$f"; then
        warn "$f também define endereços para $NET_IFACE; confira se não haverá IP duplicado"
      fi
    done
    printf '%s\n' "$novo" > "$yaml"
    chmod 600 "$yaml"
    audit REDE "netplan escrito: modo=$NET_MODE iface=$NET_IFACE ip=$ALVO_IP gw=$ALVO_GW dns=$NET_DNS"
    sed 's/^/      /' "$yaml"
    # Impede o cloud-init de regenerar a rede no boot
    if [[ -d /etc/cloud/cloud.cfg.d ]]; then
      echo "network: {config: disabled}" > /etc/cloud/cloud.cfg.d/99-heatsafe-network.cfg
    fi
    run "Validando a configuração (netplan generate)" netplan generate
    if [[ ${ALVO_IP%/*} != "${ATUAL_IP%/*}" && -n ${SSH_CONNECTION:-} ]]; then
      warn "O IP vai mudar de ${ATUAL_IP%/*} para ${ALVO_IP%/*}: a sessão SSH atual vai cair. Reconecte em ${ALVO_IP%/*}."
    fi
    run "Aplicando a rede (netplan apply)" netplan apply
    sleep 3
  fi
  # Verificações
  local ip_agora
  ip_agora=$(ip -4 -o addr show dev "$NET_IFACE" scope global | awk '{print $4; exit}')
  if [[ $NET_MODE == static && $ip_agora != "$ALVO_IP" ]]; then
    die "IP esperado $ALVO_IP, mas a interface está com ${ip_agora:-nenhum}"
  fi
  ok "IP em $NET_IFACE: $ip_agora | rota padrão via $(ip -4 route show default | awk '{print $3; exit}')"
  local i
  for ((i = 0; i < 15; i++)); do
    getent hosts archive.ubuntu.com >/dev/null 2>&1 && break
    sleep 1
  done
  if getent hosts archive.ubuntu.com >/dev/null 2>&1; then
    ok "DNS externo resolvendo (archive.ubuntu.com -> $(getent hosts archive.ubuntu.com | awk '{print $1; exit}'))"
  else
    warn "DNS externo não respondeu; verifique NET_DNS e a conectividade"
  fi
}

etapa_dns_local() {
  step "DNS local (/etc/hosts): $HS_DNS_NAMES"
  detectar_rede
  local ip=${ALVO_IP%/*} f=/etc/hosts tmp
  backup_file "$f"
  tmp=$(mktemp)
  # remove o bloco antigo do HeatSafe e a linha 127.0.1.1 (o hostname passa a apontar para o IP real)
  sed '/^# >>> HeatSafe/,/^# <<< HeatSafe/d; /^127\.0\.1\.1[[:space:]]/d' "$f" > "$tmp"
  {
    echo "# >>> HeatSafe (gerenciado por provision_infra.sh — não editar este bloco)"
    echo "$ip $HS_HOSTNAME.$HS_DOMAIN $HS_HOSTNAME $HS_DNS_NAMES"
    echo "# <<< HeatSafe"
  } >> "$tmp"
  cat "$tmp" > "$f"; rm -f "$tmp"
  chmod 644 "$f"
  audit DNS "/etc/hosts: $ip -> $HS_HOSTNAME $HS_DNS_NAMES"
  local nome resolvido
  for nome in $HS_HOSTNAME $HS_DNS_NAMES; do
    resolvido=$(getent hosts "$nome" | awk '{print $1; exit}')
    [[ $resolvido == "$ip" ]] || die "$nome resolve para '${resolvido:-nada}', esperado $ip"
    ok "$nome -> $resolvido"
  done
}

etapa_firewall() {
  step "Firewall (ufw): nega tudo, libera só SSH e HTTP"
  run "Política padrão: bloquear entrada" ufw default deny incoming
  run "Política padrão: liberar saída"   ufw default allow outgoing
  run "SSH (22) com limite anti-força-bruta" ufw limit 22/tcp comment 'SSH administracao'
  run "HTTP (80) para o nginx"            ufw allow 80/tcp comment 'HeatSafe nginx'
  run "Porta interna da API bloqueada"     ufw deny "$API_PORT/tcp" comment 'API so via nginx'
  run "Porta interna da previsão bloqueada" ufw deny "$PREVISAO_PORT/tcp" comment 'Previsao so via nginx'
  ufw logging low >/dev/null
  run "Ativando o firewall" ufw --force enable
  ufw status verbose | sed 's/^/      /'
}

etapa_ssh() {
  step "SSH endurecido"
  if [[ ! -d /etc/ssh/sshd_config.d ]]; then
    warn "openssh-server não instalado; pulando"
    return 0
  fi
  local f=/etc/ssh/sshd_config.d/60-heatsafe.conf
  {
    echo "# HeatSafe — endurecimento do SSH (provision_infra.sh)"
    # Só bloqueia login de root se o admin entrou com um usuário comum (evita se trancar fora)
    [[ -n ${SUDO_USER:-} && ${SUDO_USER} != root ]] && echo "PermitRootLogin no"
    echo "MaxAuthTries 3"
    echo "LoginGraceTime 30"
    echo "X11Forwarding no"
  } > "$f"
  chmod 644 "$f"
  audit ARQUIVO "$f"
  if sshd -t 2>/dev/null; then
    systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || true
    ok "SSH recarregado com a nova configuração"
  else
    rm -f "$f"
    warn "Configuração SSH inválida; arquivo removido para não perder o acesso"
  fi
}

etapa_auditoria() {
  step "Auditoria do sistema (auditd) e rotação de logs"
  hs_auditd_rules
  install -m 644 "$HS_INFRA_DIR/config/logrotate-heatsafe" /etc/logrotate.d/heatsafe
  audit ARQUIVO "/etc/logrotate.d/heatsafe"
  logrotate -d /etc/logrotate.d/heatsafe >/dev/null 2>&1 && ok "logrotate: /var/log/heatsafe/*.log rotaciona diariamente (14 dias)" \
    || warn "logrotate acusou problema na configuração"
}

resumo() {
  step "Resumo da infraestrutura"
  detectar_rede
  printf '      %-16s %s\n' \
    "Hostname"  "$(hostname) ($(hostname -f 2>/dev/null || echo "$HS_HOSTNAME"))" \
    "IP"        "$(ip -4 -o addr show dev "$NET_IFACE" scope global | awk '{print $4; exit}') em $NET_IFACE ($NET_MODE)" \
    "Gateway"   "$ATUAL_GW" \
    "DNS"       "$NET_DNS (+ local: $HS_DNS_NAMES)" \
    "Fuso"      "$(timedatectl show -p Timezone --value 2>/dev/null)" \
    "Usuário"   "$(id "$HS_USER")" \
    "Firewall"  "$(ufw status | head -1)" \
    "auditd"    "$(systemctl is-active auditd 2>/dev/null || echo inativo)" \
    "Logs"      "$HS_LOG"
}

main() {
  hs_init "$@"
  etapa_checagens
  etapa_pacotes
  etapa_hostname
  etapa_usuario
  etapa_scripts
  etapa_rede
  etapa_dns_local
  etapa_firewall
  etapa_ssh
  etapa_auditoria
  resumo
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
