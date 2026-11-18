#!/usr/bin/env bash
# =============================================================================
# HeatSafe · scripts/lib/common.sh
# Funções usadas por todos os scripts:
#   - carrega a configuração (config/heatsafe.conf)
#   - log de execução (tudo o que o script imprime vai para /var/log/heatsafe/<script>.log)
#   - log de auditoria (/var/log/heatsafe/auditoria.log + journald): quem, quando, o quê
#   - tratamento de erros (linha e comando que falharam)
#   - utilidades: run, backup_file, render_template, apt_install, http_code...
# Este arquivo é "source"ado; não é executado sozinho.
# =============================================================================

# Pasta infra/ (este arquivo fica em infra/scripts/lib/)
HS_INFRA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HS_REPO_DIR="$(cd "$HS_INFRA_DIR/.." && pwd)"

HS_CONF="${HEATSAFE_CONF:-$HS_INFRA_DIR/config/heatsafe.conf}"
if [[ ! -f $HS_CONF ]]; then
  echo "ERRO: configuração não encontrada: $HS_CONF" >&2
  exit 1
fi
# shellcheck source=../../config/heatsafe.conf
source "$HS_CONF"

HS_INFRA_INSTALL="$HS_BASE/infra"   # cópia instalada dos scripts (usada pelo systemd)
HS_SERVICOS=(heatsafe-api heatsafe-previsao heatsafe-monitor)

# Em Bash 5.2 o "&" na substituição ${x//a/b} é especial; desligamos.
shopt -u patsub_replacement 2>/dev/null || true

# ---------- Cores (só se a saída for um terminal) ----------
if [[ -t 1 || ${HS_COLOR:-} == 1 ]]; then
  C_RST=$'\e[0m'; C_DIM=$'\e[2m'; C_BOLD=$'\e[1m'
  C_BLUE=$'\e[1;34m'; C_GREEN=$'\e[1;32m'; C_YELLOW=$'\e[1;33m'; C_RED=$'\e[1;31m'; C_CYAN=$'\e[1;36m'
else
  C_RST=""; C_DIM=""; C_BOLD=""; C_BLUE=""; C_GREEN=""; C_YELLOW=""; C_RED=""; C_CYAN=""
fi

# ---------- Mensagens ----------
_hs_log() {
  local nivel=$1 cor=$2; shift 2
  local ts; ts=$(date '+%Y-%m-%d %H:%M:%S')
  printf '%s[%s] %-5s%s %s\n' "$cor" "$ts" "$nivel" "$C_RST" "$*" >&"${HS_TTY_FD:-1}"
  if [[ -n ${HS_EXEC_LOG:-} ]]; then
    printf '[%s] %-5s %s\n' "$ts" "$nivel" "$*" >> "$HS_EXEC_LOG" 2>/dev/null || true
  fi
}
info()  { _hs_log INFO "$C_BLUE"   "$@"; }
ok()    { _hs_log OK   "$C_GREEN"  "$@"; }
warn()  { _hs_log AVISO "$C_YELLOW" "$@"; }
error() { _hs_log ERRO "$C_RED"    "$@"; }
die()   { error "$@"; audit ABORTADO "$*"; exit 1; }

HS_STEP=0
step() {
  HS_STEP=$((HS_STEP + 1))
  local linha="==> [$HS_STEP] $*"
  printf '\n%s%s%s\n' "$C_CYAN" "$linha" "$C_RST" >&"${HS_TTY_FD:-1}"
  [[ -n ${HS_EXEC_LOG:-} ]] && printf '\n%s\n' "$linha" >> "$HS_EXEC_LOG" 2>/dev/null
  audit ETAPA "$*"
}

# ---------- Auditoria ----------
# Formato: data | host | usuário real (mesmo via sudo) | euid | script | pid | AÇÃO | detalhe
audit() {
  local acao=$1; shift
  local quem=${SUDO_USER:-$(id -un 2>/dev/null || echo '?')}
  local linha
  linha=$(printf '%s | host=%s | usuario=%s | euid=%s | script=%s | pid=%s | %s | %s' \
    "$(date --iso-8601=seconds)" "$(hostname)" "$quem" "$EUID" "${HS_SCRIPT:-?}" "$$" "$acao" "$*")
  if [[ -d $HS_LOG && -w $HS_LOG ]]; then
    printf '%s\n' "$linha" >> "$HS_LOG/auditoria.log" 2>/dev/null || true
  fi
  if command -v logger >/dev/null 2>&1; then
    logger -t heatsafe-auditoria -- "script=${HS_SCRIPT:-?} usuario=$quem $acao $*" 2>/dev/null || true
  fi
}

# Executa um comando registrando descrição, comando e resultado na auditoria.
# Uso: run "descrição" comando arg1 arg2...
run() {
  local desc=$1; shift
  info "$desc"
  printf '%s      $ %s%s\n' "$C_DIM" "$*" "$C_RST" >&"${HS_TTY_FD:-1}"
  local rc=0
  "$@" || rc=$?
  if (( rc == 0 )); then
    audit OK "$desc :: $*"
  else
    audit FALHA "$desc :: $* (código $rc)"
    error "Falhou: $desc (código $rc)"
  fi
  return "$rc"
}

# ---------- Início / fim de execução ----------
_hs_on_error() {
  [[ -n ${_HS_ERR_LOGGED:-} ]] && return
  _HS_ERR_LOGGED=1
  error "Erro na linha $1: $2"
  audit ERRO "linha $1: $2"
}
_hs_on_exit() {
  local rc=$1 dur=$(( $(date +%s) - HS_T0 ))
  if (( rc == 0 )); then
    ok "${HS_SCRIPT} concluído em ${dur}s. Log: $HS_EXEC_LOG"
    audit FIM "sucesso (duração ${dur}s)"
  else
    error "${HS_SCRIPT} terminou com erro (código $rc) após ${dur}s. Veja $HS_EXEC_LOG"
    audit FIM "falha código=$rc (duração ${dur}s)"
  fi
  exec 1>&3 2>&4
  wait "${HS_TEE_PID:-}" 2>/dev/null || true
}

# Chamar no começo de cada script executável. Liga log de execução + auditoria.
hs_init() {
  HS_SCRIPT=$(basename "$0")
  HS_T0=$(date +%s)
  mkdir -p "$HS_LOG" 2>/dev/null || true
  if [[ ! -w $HS_LOG ]]; then
    echo "ERRO: sem permissão de escrita em $HS_LOG (rode com sudo)" >&2
    exit 1
  fi
  getent group "$HS_GROUP" >/dev/null 2>&1 && chgrp "$HS_GROUP" "$HS_LOG" 2>/dev/null && chmod 2770 "$HS_LOG" 2>/dev/null
  HS_EXEC_LOG="$HS_LOG/${HS_SCRIPT%.sh}.log"
  touch "$HS_EXEC_LOG" "$HS_LOG/auditoria.log" 2>/dev/null || true
  chmod 660 "$HS_EXEC_LOG" "$HS_LOG/auditoria.log" 2>/dev/null || true
  printf '\n===== %s | %s | usuario=%s | args: %s =====\n' \
    "$(date --iso-8601=seconds)" "$HS_SCRIPT" "${SUDO_USER:-$(id -un)}" "${*:-nenhum}" >> "$HS_EXEC_LOG"
  # Duplica stdout/stderr para o arquivo de log (tee); fd 3/4 = terminal original
  exec 3>&1 4>&2
  exec > >(tee -a "$HS_EXEC_LOG") 2>&1
  HS_TEE_PID=$!
  HS_TTY_FD=3
  trap '_hs_on_error $LINENO "$BASH_COMMAND"' ERR
  trap '_hs_on_exit $?' EXIT
  audit INICIO "execução iniciada (args: ${*:-nenhum})"
}

# ---------- Utilidades ----------
require_root() {
  [[ $EUID -eq 0 ]] || die "Este script precisa de root. Rode: sudo $0"
}

# Guarda uma cópia do arquivo antes de alterá-lo (em $HS_BACKUP, com data/hora)
backup_file() {
  local f=$1
  [[ -e $f ]] || return 0
  local dest="$HS_BACKUP$(dirname "$f")"
  mkdir -p "$dest" && chmod 700 "$HS_BACKUP"
  cp -a "$f" "$dest/$(basename "$f").$(date +%Y%m%d-%H%M%S)"
  audit BACKUP "$f -> $dest/"
}

# Gera um arquivo a partir de um modelo trocando @VARIAVEL@ pelo valor da variável Bash
render_template() {
  local src=$1 dst=$2 conteudo var
  conteudo=$(<"$src")
  for var in $(grep -oE '@[A-Z_][A-Z0-9_]*@' "$src" | sort -u | tr -d '@'); do
    if [[ ! -v $var ]]; then
      error "Variável $var não definida (modelo $src)"
      return 1
    fi
    conteudo=${conteudo//@${var}@/${!var}}
  done
  printf '%s\n' "$conteudo" > "$dst"
  audit ARQUIVO "gerado $dst a partir de $(basename "$src")"
}

# Espera o apt ficar livre (logo após o boot o Ubuntu roda atualizações automáticas)
esperar_apt() {
  local i=0
  while fuser /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/lib/apt/lists/lock >/dev/null 2>&1; do
    (( i % 6 == 0 )) && info "Aguardando o apt ficar livre: o Ubuntu está instalando atualizações automáticas (${i}0s)..."
    sleep 10; i=$((i + 1))
  done
  return 0
}

apt_update_once() {
  esperar_apt
  if [[ -z ${_HS_APT_UPDATED:-} ]]; then
    export DEBIAN_FRONTEND=noninteractive
    run "Atualizando o índice de pacotes (apt-get update)" apt-get -o DPkg::Lock::Timeout=600 update -q
    _HS_APT_UPDATED=1
  fi
}
apt_install() {
  export DEBIAN_FRONTEND=noninteractive
  apt_update_once
  esperar_apt
  run "Instalando pacotes: $*" apt-get install -y -q -o DPkg::Lock::Timeout=600 -o Dpkg::Options::=--force-confold "$@"
}

# Código HTTP de uma URL ("000" se não respondeu)
http_code() {
  local c
  c=$(curl -s -o /dev/null -m "${2:-3}" -w '%{http_code}' "$1" 2>/dev/null) || true
  echo "${c:-000}"
}
# Considera "no ar" qualquer resposta HTTP entre 200 e 499 (404 = app respondeu)
http_ok() { [[ $1 =~ ^[1-4][0-9][0-9]$ ]]; }

# Espera uma URL responder; uso: wait_http URL TIMEOUT_SEGUNDOS
wait_http() {
  local url=$1 limite=${2:-60} i code
  for ((i = 0; i < limite; i++)); do
    code=$(http_code "$url")
    if http_ok "$code"; then
      ok "$url respondeu HTTP $code após ${i}s"
      return 0
    fi
    sleep 1
  done
  warn "$url não respondeu em ${limite}s (último código: $code)"
  return 1
}

servico_existe() {
  [[ $(systemctl show -p LoadState --value "$1" 2>/dev/null) == loaded ]]
}

# Copia infra/ para /opt/heatsafe/infra (é de lá que o systemd executa os scripts)
install_infra_copy() {
  [[ $HS_INFRA_DIR == "$HS_INFRA_INSTALL" ]] && return 0
  mkdir -p "$HS_INFRA_INSTALL"
  if command -v rsync >/dev/null; then
    rsync -a --delete --exclude 'evidencias/' "$HS_INFRA_DIR/" "$HS_INFRA_INSTALL/"
  else
    cp -a "$HS_INFRA_DIR/." "$HS_INFRA_INSTALL/"
  fi
  chown -R root:"$HS_GROUP" "$HS_INFRA_INSTALL"
  chmod -R u=rwX,g=rX,o= "$HS_INFRA_INSTALL"
  find "$HS_INFRA_INSTALL" -name '*.sh' -exec chmod 750 {} +
  mkdir -p "$HS_ETC"
  ln -sfn "$HS_INFRA_INSTALL/config/heatsafe.conf" "$HS_ETC/heatsafe.conf"
  audit INSTALACAO "scripts copiados para $HS_INFRA_INSTALL"
}

# Regras do auditd (auditoria do sistema operacional). Só inclui caminhos que existem.
hs_auditd_rules() {
  command -v augenrules >/dev/null || { warn "auditd não instalado; pulando regras"; return 0; }
  local f=/etc/audit/rules.d/60-heatsafe.rules
  {
    echo "## HeatSafe — regras de auditoria (gerado por ${HS_SCRIPT:-script}; consulte com: ausearch -k <chave> -i)"
    local par caminho chave
    for par in \
      "$HS_ETC/:heatsafe_config" \
      "$HS_INFRA_INSTALL/:heatsafe_scripts" \
      "/etc/systemd/system/:heatsafe_systemd" \
      "/etc/hosts:heatsafe_dns" \
      "/etc/hostname:heatsafe_dns" \
      "/etc/netplan/:heatsafe_rede" \
      "/etc/ufw/:heatsafe_firewall" \
      "/etc/nginx/sites-available/:heatsafe_nginx" \
      "/etc/ssh/sshd_config.d/:heatsafe_ssh" \
      "/etc/passwd:heatsafe_usuarios" \
      "/etc/group:heatsafe_usuarios" \
      "/etc/sudoers:heatsafe_sudo"; do
      caminho=${par%:*}; chave=${par##*:}
      [[ -e $caminho ]] && echo "-w $caminho -p wa -k $chave"
    done
    echo "## Qualquer kill -9 (SIGKILL) no sistema: mostra QUEM derrubou um processo"
    echo "-a always,exit -F arch=b64 -S kill -F a1=9 -k heatsafe_kill9"
    echo "-a always,exit -F arch=b32 -S kill -F a1=9 -k heatsafe_kill9"
  } > "$f"
  chmod 640 "$f"
  audit ARQUIVO "regras auditd em $f"
  systemctl enable --now auditd >/dev/null 2>&1 || true
  if augenrules --load >/dev/null 2>&1; then
    ok "Regras do auditd carregadas ($(grep -c '^-' "$f") regras)"
  else
    warn "Não foi possível carregar as regras do auditd agora (elas valem no próximo boot)"
  fi
}
