# Evidências técnicas

Esta pasta guarda as evidências de que a infraestrutura funciona. Elas são geradas **dentro da VM**:

```bash
sudo ./infra/scripts/teste_falha.sh todos       # gera os eventos de falha e alertas
sudo ./infra/scripts/coletar_evidencias.sh      # salva em infra/evidencias/<data-hora>/
git add infra/evidencias && git commit -m "evidencias da infra" && git push
```

## O que é coletado automaticamente

| Arquivo | Prova |
|---|---|
| `01-sistema.txt` | hostname `heatsafe-srv`, fuso, NTP, usuário de serviço, permissões das pastas |
| `02-rede.txt` | IP fixo, rotas, netplan gerado, DNS, portas em escuta (API e previsão só em 127.0.0.1) |
| `03-dns-local.txt` | `/etc/hosts` e resolução de `api.heatsafe.local`, `previsao.heatsafe.local`… |
| `04-firewall.txt` | regras do ufw |
| `05-servicos.txt` | `systemctl status`, timers, contagem de reinícios automáticos (NRestarts) |
| `06-units-systemd.txt` | units geradas e configuração do nginx |
| `07-aplicacao.txt` | respostas HTTP da API e da previsão pelo DNS, status do monitor, `.env` com segredos mascarados |
| `08-auditd.txt` | eventos do auditd (quem deu `kill -9`, quem mudou `/etc/hosts`, netplan, `.env`…) |
| `09-journal.txt` | journal dos serviços HeatSafe |
| `log-*.log` | trechos de auditoria, alertas, serviços, healthcheck, monitor e execuções |

## Prints recomendados (salvar nesta pasta como PNG)

- [ ] `provision.sh` terminando com o painel de status
- [ ] `status.sh` com todos os serviços `active`
- [ ] `teste_ponta_a_ponta.sh` terminando com "Fluxo completo funcionando"
- [ ] Swagger da API em `http://api.heatsafe.local/swagger`
- [ ] Docs da previsão em `http://previsao.heatsafe.local/swagger-ui.html`
- [ ] Página de status `http://heatsafe.local` durante o teste de CPU (barras vermelhas)
- [ ] `teste_falha.sh api`: HTTP 502 → 200 e o PID mudando
- [ ] `teste_falha.sh travar`: healthcheck destravando o monitor
- [ ] `tail /var/log/heatsafe/auditoria.log`
- [ ] `sudo ausearch -k heatsafe_kill9 -i`
