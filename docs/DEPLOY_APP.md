# Deploy de aplicações

Como subir uma aplicação de produto na VPS aerobi (`187.127.6.20`) usando Ansible (infra)
+ GitHub Actions (deploy contínuo). Padrão: container Docker bind em `127.0.0.1`, imagem no
GHCR, atrás do nginx do host com TLS via Let's Encrypt.

## Divisão de responsabilidades

O **Ansible** (este repo) cuida da **infra**, uma vez por aplicação:
- Diretório da app em `/home/deploy/apps/<app_name>` (a role cria; o workflow de deploy também
  garante com `mkdir -p`).
- Virtual host nginx (reverse proxy para `127.0.0.1:<porta>`).
- Certificado SSL via Certbot (`roles/nginx_vhost`, flag `--reinstall`).

O **GitHub Actions** (no repo da app) cuida do **deploy contínuo**, a cada push na `main`:
- `semantic-release` cria a tag/release.
- Build da imagem Docker e push no GitHub Container Registry (GHCR).
- Via SSH: transfere `docker-compose.yml` + `.env`, `docker compose pull && up -d`.

> O container expõe a porta **apenas em `127.0.0.1`** e entra na rede Docker `warpgate`
> (`external: true`). Exposição pública (TLS) é responsabilidade do nginx — nunca publique a
> porta em `0.0.0.0` nem via `-p` em IP público (Docker NAT fura o UFW — ver CLAUDE.md regra 2).

## Apps de produto na VPS

| App | Domínio | Porta interna | Repo | Estado |
|---|---|---|---|---|
| `aerobi-api` | `api.aerobi.com.br` | 3333 | `atzaero/aerobi-api` | produção |
| `aerobi-web` | `aerobi.com.br` + `www` | 3000 | `atzaero/aerobi` | **migração** (Firebase → VPS; cutover de DNS pendente) |

Infra compartilhada (Vaultwarden, MinIO, Headscale, etc) está em [`DOMINIOS.md`](DOMINIOS.md)
e [`PORTAS.md`](PORTAS.md).

---

## Passo a passo — nova aplicação

### 1. Escolher a porta interna

Cada app escuta numa porta distinta em `127.0.0.1`. Consulte o mapa em [`PORTAS.md`](PORTAS.md)
e a tabela acima antes de alocar.

### 2. Criar o registro DNS (Registro.br)

A zona `aerobi.com.br` é gerenciada no **Registro.br** (NS `*.sec.dns.br`), **não** no Hostinger
— o MCP da Hostinger não edita esse DNS. Crie o A `<sub> → 187.127.6.20` pelo painel e aguarde
propagar. Procedimento detalhado em [`REGISTRO_BR.md`](REGISTRO_BR.md).

```bash
dig +short <sub>.aerobi.com.br @1.1.1.1   # deve retornar 187.127.6.20
```

O Certbot valida via HTTP-01 — **sem DNS resolvendo para a VPS, a emissão do cert falha**.

### 3. Banco de dados (só se a app usar PostgreSQL)

Adicione a app em `inventory/prod/group_vars/all/all.yml` (`postgres_apps`), a senha no vault, e
rode `ansible-playbook playbooks/setup_app_databases.yml`. (O `aerobi-web` usa Firebase — não
precisa deste passo.)

### 4. Provisionar vhost + SSL

```bash
ansible-playbook playbooks/setup_app.yml \
  -e "app_name=<app> app_domain=<dominio> app_port=<porta>"
```

Flags opcionais (lidas direto pela role `nginx_vhost`):

| Flag | Para quê |
|---|---|
| `vhost_client_max_body_size=12m` | Override do default 1m do nginx (uploads grandes). |
| `vhost_server_aliases=['www.aerobi.com.br']` | Domínios extras no mesmo vhost/cert (passar via `-e` JSON). |
| `vhost_websocket_enabled=true` | Apps com WebSocket (MinIO console, Uptime Kuma). |
| `vhost_tailnet_only=true` | Restringe ao range tailnet `100.64.0.0/10` (admin-only). |
| `vhost_emit_cert=false` | Cria só o vhost HTTP, pula o Certbot (1ª passada de cutover — ver abaixo). |

**Exemplo `aerobi-web`** (apex + www, upload de documentos do Next `bodySizeLimit=10mb`):

```bash
ansible-playbook playbooks/setup_app.yml \
  -e '{"app_name":"aerobi-web","app_domain":"aerobi.com.br","app_port":3000,"vhost_client_max_body_size":"12m","vhost_server_aliases":["www.aerobi.com.br"]}'
```

> `vhost_client_max_body_size=12m` é **obrigatório** no `aerobi-web`: sem ele, o upload de
> documentos (até 10mb) retorna **413** (default nginx = 1m).

### 5. `docker-compose.yml` no repo da app

Bind apenas em loopback, rede `warpgate` externa:

```yaml
services:
  web:
    image: ${REGISTRY}/${IMAGE_NAME}:${TAG}
    ports:
      - "127.0.0.1:3000:3000"   # nunca "3000:3000" (expõe à internet)
    networks: [warpgate]
networks:
  warpgate:
    external: true
```

### 6. GitHub Secrets no repo da app

`Settings → Secrets and variables → Actions` (ou Environment `prod`):

| Secret | Valor |
|---|---|
| `SSH_PRIVATE_KEY` | Chave privada `github-actions-cicd` (compartilhada entre os apps). |
| `REMOTE_USER` | `deploy` |
| `REMOTE_HOST` | `187.127.6.20` |
| `REMOTE_PORT` | `22` |
| `REMOTE_TARGET` | `/home/deploy/apps/<app_name>` |
| `GH_TOKEN` | PAT para GHCR/releases. |
| + vars da app | NEXT_PUBLIC_*, runtime, etc. |

### 7. Disparar o deploy

Push na `main` do repo da app → o pipeline builda, publica no GHCR e faz `docker compose up -d`
na VPS.

---

## Cutover de apex (migração de provedor → VPS)

Quando o domínio **já está em produção em outro provedor** (ex: `aerobi.com.br` no Firebase App
Hosting) e vamos virar o A para a VPS, há uma tensão de ordem: o Certbot (HTTP-01) só emite o cert
com o domínio **já resolvendo para a VPS**, mas virar o A antes do app estar de pé **derruba a
produção**. O nginx da VPS não tem `default_server` — sem o vhost, um A apontado para a VPS cai
num vhost arbitrário.

Sequência de **2 passadas** (downtime funcional ~0; janela HTTP-only de minutos):

**Pré-condição:** container já rodando na VPS (`127.0.0.1:<porta>`, healthcheck ok).

0. **(Registro.br, ~1h antes)** baixar o TTL do A de `aerobi.com.br` e `www` para `60` (rollback rápido).
1. **Validar o container:**
   ```bash
   ssh deploy@187.127.6.20 "docker ps | grep aerobi-web"
   ssh deploy@187.127.6.20 "curl -sf http://127.0.0.1:3000/api/health"
   ```
2. **1ª passada — vhost só-HTTP, sem cert** (produção ainda no provedor antigo):
   ```bash
   ansible-playbook playbooks/setup_app.yml \
     -e '{"app_name":"aerobi-web","app_domain":"aerobi.com.br","app_port":3000,"vhost_client_max_body_size":"12m","vhost_server_aliases":["www.aerobi.com.br"],"vhost_emit_cert":false}'
   # valida via Host header (sem depender do DNS):
   ssh deploy@187.127.6.20 'curl -s -H "Host: aerobi.com.br" http://127.0.0.1/api/health'
   ```
3. **(Registro.br, manual)** virar o A de `aerobi.com.br` e `www`: `35.219.200.207 → 187.127.6.20`.
4. **Aguardar propagação:**
   ```bash
   for r in 1.1.1.1 8.8.8.8 9.9.9.9; do dig +short aerobi.com.br @$r; done   # → 187.127.6.20
   ```
5. **2ª passada — emite cert (apex + www) e ativa redirect 80→443:**
   ```bash
   ansible-playbook playbooks/setup_app.yml \
     -e '{"app_name":"aerobi-web","app_domain":"aerobi.com.br","app_port":3000,"vhost_client_max_body_size":"12m","vhost_server_aliases":["www.aerobi.com.br"]}'
   ```
6. **Validar:** `curl -I https://aerobi.com.br` e `https://www.aerobi.com.br` (200 + SSL válido),
   upload de ~10mb sem 413, `api.aerobi.com.br` intacto.

**Rollback:** reverter o A para o IP antigo no Registro.br (com TTL 60, volta em minutos). O
container e o vhost na VPS ficam inertes sem DNS.

---

## Operação

```bash
# Containers rodando
ssh deploy@187.127.6.20 "docker ps"

# Logs de uma app
ssh deploy@187.127.6.20 "docker logs aerobi-web --tail 50"

# Config do vhost
ssh deploy@187.127.6.20 "cat /etc/nginx/sites-available/aerobi-web"
```

**Renovação SSL:** automática via `systemd timer` do Certbot.
`ssh deploy@187.127.6.20 "sudo certbot renew --dry-run"` para testar.

### Remover uma app

```bash
ssh deploy@187.127.6.20 "cd ~/apps/<app> && docker compose down && rm -rf ~/apps/<app>"
ssh deploy@187.127.6.20 "sudo rm /etc/nginx/sites-{enabled,available}/<app> && sudo nginx -t && sudo systemctl reload nginx"
ssh deploy@187.127.6.20 "sudo certbot delete --cert-name <dominio>"   # opcional
```
