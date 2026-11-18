#!/usr/bin/env bash
# =============================================================================
# HeatSafe · provision_app.sh  (critério: provisionamento da aplicação —
#                                dependências, configurações, orquestração)
#
# Sobe as duas partes do HeatSafe que rodam no servidor, direto dos
# repositórios do grupo no GitHub:
#   - Serviço de previsão (SOA): Java 21 / Spring Boot + MySQL
#       repo GS-HeatSafe-SOA     -> heatsafe-previsao.service (127.0.0.1:8000)
#   - API central: C# / ASP.NET Core (.NET 10) + SQLite
#       repo HeatSafe-Backend    -> heatsafe-api.service      (127.0.0.1:5000)
#   e o nginx na frente: previsao.heatsafe.local e api.heatsafe.local (porta 80)
#
# Etapas: dependências -> código -> bancos -> variáveis (.env) -> previsão
#         -> API -> nginx -> testes de fumaça
# Uso:   sudo ./provision_app.sh       (rode depois do provision_infra.sh)
# Para atualizar depois que os colegas mudarem o código: rode de novo.
# =============================================================================
set -Eeuo pipefail
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/common.sh"

API_SRC="$HS_APP_DIR/api"
PREVISAO_SRC="$HS_APP_DIR/previsao"
API_STATUS="não instalado"
PREVISAO_STATUS="não instalado"

etapa_checagens() {
  step "Checagens"
  require_root
  id "$HS_USER" >/dev/null 2>&1 || die "Usuário $HS_USER não existe. Rode antes: sudo ./provision_infra.sh"
  install_infra_copy
  local mem; mem=$(awk '/^MemTotal:/{print int($2/1024)}' /proc/meminfo)
  (( mem >= 3000 )) || warn "A VM tem ${mem} MB de RAM; para compilar .NET + Java o recomendado é 4096 MB"
  ok "Infra base encontrada (usuário $HS_USER, pastas em $HS_BASE, ${mem} MB de RAM)"
}

etapa_dependencias() {
  step "Dependências do sistema (nginx, Java $JAVA_VERSION, MySQL, bibliotecas do .NET)"
  apt_install nginx git curl jq rsync unzip sqlite3 libicu-dev ca-certificates \
              "openjdk-${JAVA_VERSION}-jdk-headless" mysql-server
  ok "nginx $(nginx -v 2>&1 | awk -F/ '{print $2}') | $(java -version 2>&1 | head -1) | $(mysqld --version | awk '{print $1, $3}')"
}

# obter_repo URL BRANCH DESTINO -> clona ou atualiza para a última versão do branch
obter_repo() {
  local url=$1 branch=$2 destino=$3 commit
  if [[ -d $destino/.git ]]; then
    run "Atualizando $(basename "$destino") (branch $branch)" git -C "$destino" fetch --depth 1 origin "$branch"
    git -C "$destino" reset -q --hard FETCH_HEAD
    git -C "$destino" clean -qfd
  else
    rm -rf "$destino"
    run "Clonando $url (branch $branch)" git clone -q --depth 1 --branch "$branch" "$url" "$destino"
  fi
  commit=$(git -C "$destino" log -1 --format='%h %ad %s' --date=short)
  audit CODIGO "$url@$branch -> $destino ($commit)"
  ok "$(basename "$destino"): $commit"
}

etapa_codigo() {
  step "Código da aplicação (repositórios do grupo no GitHub)"
  install -d -o root -g "$HS_GROUP" -m 0750 "$HS_APP_DIR"
  obter_repo "$PREVISAO_REPO_URL" "$PREVISAO_REPO_BRANCH" "$PREVISAO_SRC"
  obter_repo "$API_REPO_URL" "$API_REPO_BRANCH" "$API_SRC"
}

# ---------- Bancos de dados ----------
DB_PASSWORD=""
etapa_bancos() {
  step "Bancos de dados: MySQL (previsão) e SQLite (API)"
  # Reaproveita a senha já gerada (o .env não é recriado do zero a cada execução)
  [[ -f $HS_ENV_PREVISAO ]] && DB_PASSWORD=$(sed -n 's/^DB_PASSWORD="\(.*\)"$/\1/p' "$HS_ENV_PREVISAO")
  DB_PASSWORD=${DB_PASSWORD:-$(openssl rand -hex 16)}

  run "Ligando o MySQL" systemctl enable --now mysql
  local h
  {
    echo "CREATE DATABASE IF NOT EXISTS \`$MYSQL_DB\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
    for h in localhost 127.0.0.1; do
      echo "CREATE USER IF NOT EXISTS '$MYSQL_USER'@'$h' IDENTIFIED BY '$DB_PASSWORD';"
      echo "ALTER USER '$MYSQL_USER'@'$h' IDENTIFIED BY '$DB_PASSWORD';"
      echo "GRANT ALL PRIVILEGES ON \`$MYSQL_DB\`.* TO '$MYSQL_USER'@'$h';"
    done
    echo "FLUSH PRIVILEGES;"
  } | mysql --protocol=socket -uroot
  audit BANCO "MySQL: banco $MYSQL_DB e usuário $MYSQL_USER (só localhost)"
  ok "MySQL: banco '$MYSQL_DB', usuário '$MYSQL_USER' (acesso só local, porta 3306 fechada para fora)"

  install -d -o "$HS_USER" -g "$HS_GROUP" -m 0750 "$HS_DATA/api"
  ok "SQLite da API: $HS_DATA/api/heatsafe.db (criado pela própria API ao iniciar)"
}

# ---------- Variáveis de ambiente ----------
# grava_env ARQUIVO (conteúdo vem do stdin) -> 640 root:heatsafe, com backup do anterior
grava_env() {
  local destino=$1 tmp; tmp=$(mktemp)
  cat > "$tmp"
  [[ -f $destino ]] && backup_file "$destino"
  install -o root -g "$HS_GROUP" -m 0640 "$tmp" "$destino"
  rm -f "$tmp"
  audit CONFIG "$destino gerado (segredos preservados entre execuções)"
}
mostra_env() {
  sed -E '/^\s*(#|$)/d; s/^((Jwt__SigningKey|DB_PASSWORD)=).*/\1"********"/' "$1" | sed 's/^/      /'
}

etapa_env() {
  step "Variáveis de ambiente (um arquivo por serviço: cada um só vê os próprios segredos)"
  local jwt=""
  [[ -f $HS_ENV_API ]] && jwt=$(sed -n 's/^Jwt__SigningKey="\(.*\)"$/\1/p' "$HS_ENV_API")
  jwt=${jwt:-$(openssl rand -hex 32)}

  grava_env "$HS_ENV_PREVISAO" <<EOF
# HeatSafe · serviço de previsão (Java/Spring Boot) — gerado por provision_app.sh
# em $(date --iso-8601=seconds). NÃO versionar (contém a senha do banco).
PORT="$PREVISAO_PORT"
SERVER_ADDRESS="127.0.0.1"
SERVER_FORWARD_HEADERS_STRATEGY="framework"
DB_URL="jdbc:mysql://localhost:3306/$MYSQL_DB?allowPublicKeyRetrieval=true&useSSL=false"
DB_USER="$MYSQL_USER"
DB_PASSWORD="$DB_PASSWORD"
CARREGAR_INMET="true"
CORS_ALLOWED_ORIGINS="http://api.$HS_DOMAIN,http://$HS_DOMAIN,http://localhost:8081,http://localhost:3000"
TZ="$HS_TIMEZONE"
EOF

  grava_env "$HS_ENV_API" <<EOF
# HeatSafe · API central (ASP.NET Core) — gerado por provision_app.sh
# em $(date --iso-8601=seconds). NÃO versionar (contém a chave do JWT).
# O ASP.NET lê "Secao__Chave" como Secao:Chave do appsettings.json.
ASPNETCORE_ENVIRONMENT="$ASPNET_ENV"
ASPNETCORE_URLS="http://127.0.0.1:$API_PORT"
ConnectionStrings__${API_CONN_NAME}="Data Source=$HS_DATA/api/heatsafe.db;Cache=Shared"
Forecast__BaseUrl="http://previsao.$HS_DOMAIN/"
Forecast__Station="A701"
Jwt__SigningKey="$jwt"
DOTNET_CLI_TELEMETRY_OPTOUT="1"
TZ="$HS_TIMEZONE"
EOF
  ok "$HS_ENV_PREVISAO (640 root:$HS_GROUP):"; mostra_env "$HS_ENV_PREVISAO"
  ok "$HS_ENV_API (640 root:$HS_GROUP):";      mostra_env "$HS_ENV_API"
}

# troca "atômica": a versão nova entra no lugar e a anterior fica guardada para rollback
publicar() {  # publicar ORIGEM DESTINO
  local origem=$1 destino=$2
  rm -rf "$destino.anterior"
  [[ -e $destino ]] && mv "$destino" "$destino.anterior"
  mv "$origem" "$destino"
  chown -R root:"$HS_GROUP" "$destino"; chmod -R u=rwX,g=rX,o= "$destino"
  audit DEPLOY "$destino publicado (anterior em $destino.anterior)"
}

subir_servico() {  # subir_servico NOME URL_HEALTH TIMEOUT
  local svc=$1 url=$2 limite=$3
  systemctl daemon-reload
  run "Habilitando no boot e (re)iniciando $svc" \
    bash -c "systemctl enable $svc >/dev/null 2>&1 && systemctl restart $svc"
  info "Aguardando $svc responder em $url (até ${limite}s)..."
  if wait_http "$url" "$limite"; then
    echo "no ar (PID $(systemctl show -p MainPID --value "$svc"))"
  else
    journalctl -u "$svc" -n 25 --no-pager -o cat 2>/dev/null | sed 's/^/      /' >&"${HS_TTY_FD:-1}" || true
    echo "FALHOU — veja: journalctl -u $svc -n 80"
  fi
}

# ---------- Serviço de previsão (Java) ----------
etapa_previsao() {
  step "Serviço de previsão (Java $JAVA_VERSION / Spring Boot + MySQL)"
  [[ -f $PREVISAO_SRC/pom.xml ]] || { warn "pom.xml não encontrado em $PREVISAO_SRC; pulando"; PREVISAO_STATUS="pulado"; return 0; }
  export HOME=/root
  info "Compilando com o Maven Wrapper (a 1ª vez baixa as dependências: alguns minutos)..."
  run "Gerando o .jar (mvnw package, sem testes: os testes usam H2 e rodam no CI do colega)" \
    bash -c "cd '$PREVISAO_SRC' && sh ./mvnw -B -ntp -DskipTests package"
  local jar
  jar=$(find "$PREVISAO_SRC/target" -maxdepth 1 -name '*.jar' ! -name '*plain*' | head -1)
  [[ -f $jar ]] || die "O build não gerou o .jar em $PREVISAO_SRC/target"
  rm -rf "$HS_PREVISAO_DIR.novo"; install -d "$HS_PREVISAO_DIR.novo"
  cp "$jar" "$HS_PREVISAO_DIR.novo/heatsafe-previsao.jar"
  publicar "$HS_PREVISAO_DIR.novo" "$HS_PREVISAO_DIR"
  ok ".jar publicado: $HS_PREVISAO_DIR/heatsafe-previsao.jar ($(du -h "$HS_PREVISAO_DIR/heatsafe-previsao.jar" | cut -f1))"

  JAVA_BIN=$(readlink -f "$(command -v java)")
  PREVISAO_JAR="$HS_PREVISAO_DIR/heatsafe-previsao.jar"
  render_template "$HS_INFRA_DIR/systemd/heatsafe-previsao.service" /etc/systemd/system/heatsafe-previsao.service
  info "Na 1ª subida o Flyway cria as tabelas e o serviço importa os 3.996 dias do INMET"
  PREVISAO_STATUS=$(subir_servico heatsafe-previsao "http://127.0.0.1:$PREVISAO_PORT$PREVISAO_HEALTH_PATH" 180)
}

# ---------- API (.NET) ----------
instalar_dotnet() {
  local canal=$1
  if command -v dotnet >/dev/null && dotnet --list-sdks 2>/dev/null | grep -q "^$canal\."; then
    ok ".NET SDK $canal já instalado ($(dotnet --version))"
    return 0
  fi
  esperar_apt
  if apt-cache show "dotnet-sdk-$canal" >/dev/null 2>&1 \
     && run "Instalando .NET SDK $canal (apt)" apt-get install -y -q -o DPkg::Lock::Timeout=600 "dotnet-sdk-$canal"; then
    return 0
  fi
  info "dotnet-sdk-$canal não está no apt do Ubuntu; usando o instalador oficial da Microsoft"
  run "Baixando dotnet-install.sh" curl -fsSL https://dot.net/v1/dotnet-install.sh -o /tmp/dotnet-install.sh
  run "Instalando .NET SDK $canal em /usr/share/dotnet" \
    bash /tmp/dotnet-install.sh --channel "$canal" --install-dir /usr/share/dotnet
  ln -sfn /usr/share/dotnet/dotnet /usr/local/bin/dotnet
  hash -r
  ok ".NET SDK instalado: $(dotnet --version)"
}

etapa_api() {
  step "API central (C# / ASP.NET Core)"
  local csproj="$API_SRC/$API_CSPROJ" tfm canal nome
  [[ -f $csproj ]] || { warn "$API_CSPROJ não encontrado em $API_SRC; pulando a API"; API_STATUS="pulado"; return 0; }
  tfm=$(grep -oPm1 '(?<=<TargetFramework>)[^<]+' "$csproj" || true)
  canal=${DOTNET_CHANNEL:-$(sed -nE 's/^net([0-9]+\.[0-9]+).*/\1/p' <<<"$tfm")}
  canal=${canal:-10.0}
  info "Projeto ${API_CSPROJ} | TargetFramework ${tfm:-?} -> .NET SDK $canal"
  instalar_dotnet "$canal"

  export DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_NOLOGO=1 DOTNET_SKIP_FIRST_TIME_EXPERIENCE=1 HOME=/root
  rm -rf "$HS_API_DIR.novo"
  run "Compilando e publicando (dotnet publish -c Release)" \
    bash -c "cd '$API_SRC' && dotnet publish '$csproj' -c Release -o '$HS_API_DIR.novo' --nologo -v minimal"
  publicar "$HS_API_DIR.novo" "$HS_API_DIR"

  nome=$(grep -oPm1 '(?<=<AssemblyName>)[^<]+' "$csproj" || true)
  nome=${nome:-$(basename "$csproj" .csproj)}
  API_DLL="$HS_API_DIR/$nome.dll"
  [[ -f $API_DLL ]] || die "Não encontrei $API_DLL após o publish"
  ok "API publicada: $API_DLL"
  DOTNET_BIN=$(readlink -f "$(command -v dotnet)")
  DOTNET_ROOT=$(dirname "$DOTNET_BIN")

  if grep -rqE 'Database\.Migrate(Async)?\(' --include='*.cs' "$API_SRC"; then
    info "Migrações do EF Core: a própria API aplica ao iniciar (Database.MigrateAsync) e cria os dados de exemplo"
  else
    warn "A API não chama Database.Migrate(); o banco pode precisar de 'dotnet ef database update'"
  fi

  render_template "$HS_INFRA_DIR/systemd/heatsafe-api.service" /etc/systemd/system/heatsafe-api.service
  API_STATUS=$(subir_servico heatsafe-api "http://127.0.0.1:$API_PORT$API_HEALTH_PATH" 120)
}

etapa_nginx() {
  step "nginx (proxy reverso na porta 80)"
  render_template "$HS_INFRA_DIR/nginx/heatsafe.conf" /etc/nginx/sites-available/heatsafe.conf
  ln -sfn /etc/nginx/sites-available/heatsafe.conf /etc/nginx/sites-enabled/heatsafe.conf
  rm -f /etc/nginx/sites-enabled/default
  install -o "$HS_USER" -g "$HS_GROUP" -m 0644 "$HS_INFRA_DIR/nginx/status/index.html" "$HS_STATUS_DIR/index.html"
  run "Validando a configuração (nginx -t)" nginx -t
  run "Ligando o nginx" systemctl enable --now nginx
  run "Recarregando o nginx" systemctl reload nginx
  hs_auditd_rules >/dev/null
}

etapa_testes() {
  step "Testes de fumaça (pelo nome DNS, passando pelo nginx)"
  local url code
  for url in "http://previsao.$HS_DOMAIN$PREVISAO_HEALTH_PATH" "http://previsao.$HS_DOMAIN$PREVISAO_DOCS_PATH" \
             "http://api.$HS_DOMAIN$API_HEALTH_PATH" "http://api.$HS_DOMAIN$API_DOCS_PATH"; do
    code=$(http_code "$url" 10)
    if http_ok "$code"; then ok "$url -> HTTP $code"; else warn "$url -> HTTP $code"; fi
  done
  local corpo
  corpo=$(curl -s -m 15 "http://previsao.$HS_DOMAIN/previsao/amanha?estacao=A701" || true)
  info "Contrato usado pela API C#: GET /previsao/amanha?estacao=A701 -> ${corpo:-sem resposta}"
}

resumo() {
  step "Resumo da aplicação"
  printf '      %-22s %s\n' \
    "Previsão (Java)"     "$PREVISAO_STATUS" \
    "API C# (.NET)"       "$API_STATUS" \
    "MySQL"               "$(systemctl is-active mysql)" \
    "nginx"               "$(systemctl is-active nginx)" \
    "Swagger da API"      "http://api.$HS_DOMAIN$API_DOCS_PATH" \
    "Swagger da previsão" "http://previsao.$HS_DOMAIN$PREVISAO_DOCS_PATH" \
    "Variáveis"           "$HS_ENV_API | $HS_ENV_PREVISAO" \
    "Logs"                "journalctl -u heatsafe-api -u heatsafe-previsao | $HS_LOG/servicos.log"
  audit RESUMO "previsao=[$PREVISAO_STATUS] api=[$API_STATUS]"
  [[ $PREVISAO_STATUS == no\ ar* && $API_STATUS == no\ ar* ]] \
    || warn "Algum serviço não subiu. Veja as mensagens acima e o journalctl indicado."
}

main() {
  hs_init "$@"
  etapa_checagens
  etapa_dependencias
  etapa_codigo
  etapa_bancos
  etapa_env
  etapa_previsao
  etapa_api
  etapa_nginx
  etapa_testes
  resumo
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
