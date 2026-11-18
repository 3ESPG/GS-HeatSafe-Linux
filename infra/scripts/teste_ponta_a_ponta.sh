#!/usr/bin/env bash
# =============================================================================
# HeatSafe · teste_ponta_a_ponta.sh  (critério: funcionamento completo)
#
# Percorre o fluxo do HeatSafe de verdade, pelos nomes DNS e pelo nginx:
#   1. serviço de previsão (Java) responde e entrega a previsão de amanhã
#   2. API C# responde
#   3. "ESP32": pega um token de dispositivo e envia uma leitura de calor perigoso
#   4. "família/admin": consulta o status da residência (alerta gerado?)
#   5. "agente da UBS": consulta a lista de visitas prioritárias
# Usa os usuários de demonstração da API (ambiente Development).
# Uso: ./teste_ponta_a_ponta.sh      (não precisa de sudo)
# =============================================================================
set -uo pipefail
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/common.sh"

API="http://api.$HS_DOMAIN"
PREV="http://previsao.$HS_DOMAIN"
FALHAS=0

# chama METODO URL [TOKEN] [CORPO_JSON] -> define HTTP e CORPO
chama() {
  local metodo=$1 url=$2 token=${3:-} dados=${4:-} saida
  local args=(-s -m 20 -X "$metodo" -H 'Accept: application/json' -w $'\n%{http_code}')
  [[ -n $token ]] && args+=(-H "Authorization: Bearer $token")
  [[ -n $dados ]] && args+=(-H 'Content-Type: application/json' -d "$dados")
  saida=$(curl "${args[@]}" "$url" 2>/dev/null || true)
  HTTP=${saida##*$'\n'}
  CORPO=${saida%$'\n'*}
  [[ $HTTP =~ ^[0-9]{3}$ ]] || { HTTP=000; CORPO=""; }
}

mostra() {  # mostra "descrição" CODIGOS_ESPERADOS
  local desc=$1 esperado=$2
  if [[ $HTTP =~ ^($esperado)$ ]]; then
    ok "$desc -> HTTP $HTTP"
  else
    error "$desc -> HTTP $HTTP (esperado $esperado)"
    FALHAS=$((FALHAS + 1))
  fi
  if [[ -n $CORPO ]]; then
    (jq -C . <<<"$CORPO" 2>/dev/null || echo "$CORPO") | head -n 25 | sed 's/^/      /' >&"${HS_TTY_FD:-1}"
    (jq . <<<"$CORPO" 2>/dev/null || echo "$CORPO") | head -n 25 | sed 's/^/      /' >> "$HS_EXEC_LOG"
  fi
}

token() {  # token USUARIO SENHA -> imprime o accessToken
  chama POST "$API/auth/token" "" "{\"username\":\"$1\",\"password\":\"$2\"}"
  jq -r '.accessToken // empty' <<<"$CORPO" 2>/dev/null
}

main() {
  hs_init "$@"
  trap - ERR   # aqui as falhas são tratadas e contadas uma a uma

  step "1. Serviço de previsão (Java/Spring Boot) em $PREV"
  chama GET "$PREV$PREVISAO_HEALTH_PATH";                     mostra "Health da previsão" 200
  chama GET "$PREV/previsao/amanha?estacao=A701";             mostra "Previsão de amanhã (contrato usado pela API C#)" 200

  step "2. API central (C#/.NET) em $API"
  chama GET "$API$API_HEALTH_PATH";                           mostra "Health da API" 200

  step "3. ESP32: token de dispositivo e leitura de calor perigoso"
  local tdev agora leitura
  tdev=$(token dispositivo 'Device@123')
  if [[ -n $tdev ]]; then ok "Token do dispositivo HS-001 obtido (${#tdev} caracteres)"
  else error "Não consegui o token do dispositivo (a API está em Development?)"; FALHAS=$((FALHAS + 1)); fi
  agora=$(date '+%Y-%m-%dT%H:%M:%S')
  leitura="{\"dispositivoId\":\"HS-001\",\"temperatura\":38.5,\"umidade\":65,\"indiceCalor\":52.0,\"nivel\":\"PERIGO\",\"movimento\":false,\"dataHora\":\"$agora\"}"
  info "POST /leituras $leitura"
  chama POST "$API/leituras" "$tdev" "$leitura";              mostra "Leitura enviada pelo dispositivo" '200|201|202'

  step "4. Família / administrador: status da residência 1"
  local tadm
  tadm=$(token admin 'Admin@123')
  [[ -n $tadm ]] && ok "Token de administrador obtido"
  chama GET "$API/residencias/1/status" "$tadm";              mostra "GET /residencias/1/status" 200

  step "5. Agente da UBS: visitas prioritárias"
  local tag
  tag=$(token agente 'Agente@123')
  chama GET "$API/visitas/prioritarias" "${tag:-$tadm}";      mostra "GET /visitas/prioritarias" 200

  step "Resultado"
  if (( FALHAS == 0 )); then
    ok "Fluxo completo funcionando: ESP32 -> API C# -> alertas/visitas, e previsão (SOA) respondendo pelo DNS"
    audit TESTE_E2E "sucesso"
  else
    error "$FALHAS verificação(ões) falharam; veja acima"
    audit TESTE_E2E "$FALHAS falha(s)"
  fi
}

main "$@"
