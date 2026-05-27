# DNS no Registro.br

O domínio `aerobi.com.br` é registrado e gerenciado no [Registro.br](https://registro.br). Subdomínios da infra (apontando para a VPS de produção `187.127.6.20`) são criados via painel.

## Quando precisa criar registro

Antes de **qualquer** `ansible-playbook playbooks/setup_app.yml -e "app_domain=<sub>.aerobi.com.br ..."`. O Certbot valida o domínio via challenge HTTP-01 (Let's Encrypt bate em `http://<dom>/.well-known/acme-challenge/...`); sem DNS resolvendo, o cert não é emitido.

## Lista atual / planejada

Subdomínios em uso ou previstos:

| Subdomínio | Tipo | Valor | TTL | Serviço | Provisionado por |
|---|---|---|---|---|---|
| `@` (apex) | A | `187.127.6.20` | 3600 | `aerobi-web` | **cutover pendente** — hoje `35.219.200.207` (Firebase). Ver "Cutover de apex" abaixo |
| `www` | A | `187.127.6.20` | 3600 | `aerobi-web` | **cutover pendente** — hoje `35.219.200.207` (Firebase). Vira junto com o apex |
| `api` | A | `187.127.6.20` | 3600 | `aerobi-api` | `setup_app.yml` |
| `vault` | A | `187.127.6.20` | 3600 | Vaultwarden | `setup_vaultwarden.yml` |
| `headscale` | A | `187.127.6.20` | 3600 | Headscale | `setup_headscale.yml` |
| `s3` | A | `187.127.6.20` | 3600 | MinIO API | `setup_minio.yml` + `setup_app.yml` |
| `s3-console` | A | `187.127.6.20` | 3600 | MinIO Console | `setup_minio.yml` + `setup_app.yml` |
| `status` | A | `187.127.6.20` | 3600 | Uptime Kuma | `setup_uptime_kuma.yml` + `setup_app.yml` |

> Mesmo subdomínios atendidos por vhosts **tailnet-only** (`s3-console`, `status`) precisam ter A record público. O bloqueio de acesso é feito no nginx (`allow 100.64.0.0/10; deny all;`) — o DNS continua precisando resolver para o IP da VPS para o Certbot emitir cert.

## Como criar (passo a passo)

1. Acessar [registro.br](https://registro.br/login/).
2. **Painel `aerobi.com.br`** → menu **DNS**.
3. Botão **Editar zona** (ou **Adicionar registro**, dependendo da UI atual do painel).
4. Para cada subdomínio:
   - **Nome**: somente o prefixo (ex: `s3`, não `s3.aerobi.com.br`).
   - **Tipo**: `A`.
   - **Dados**: `187.127.6.20`.
   - **TTL**: `3600` (1 h) é razoável. O Registro.br aceita valores entre `60` e `604800`.
5. **Salvar** / **Publicar zona**.

## Validar propagação

```bash
for sub in s3 s3-console status; do
  echo -n "$sub.aerobi.com.br → "
  dig +short "$sub.aerobi.com.br" @1.1.1.1
done
```

Saída esperada: `187.127.6.20` para cada um. Se ainda não propagou, repetir após alguns minutos. TTL `3600` significa que mudanças levam até 1 hora (geralmente menos para registros novos).

## Múltiplos resolvers (descartar cache local)

```bash
for sub in s3 s3-console status; do
  echo "=== $sub ==="
  for resolver in 1.1.1.1 8.8.8.8 9.9.9.9; do
    echo -n "  $resolver: "
    dig +short "$sub.aerobi.com.br" @$resolver
  done
done
```

Quando 3 resolvers diferentes retornam `187.127.6.20`, propagação está ok.

## Tempo típico de propagação

- **Registro novo**: 5–30 min (a maioria dos resolvers atende em <10 min).
- **Mudança de A existente**: até o TTL antigo expirar (até 1 h com TTL `3600`; até 4 h com TTL padrão `14400` da Registro.br).
- Para mudanças planejadas, baixar o TTL para `60` ~24 h antes facilita rollback rápido.

## Sequência típica antes de aplicar um vhost novo

```bash
# 1. Criar A record no painel (passo a passo acima).

# 2. Aguardar propagação:
dig +short <sub>.aerobi.com.br @1.1.1.1
# → 187.127.6.20

# 3. Aplicar role do serviço (sobe container em 127.0.0.1):
ansible-playbook playbooks/setup_<servico>.yml

# 4. Criar vhost + emitir cert via setup_app.yml:
ansible-playbook playbooks/setup_app.yml \
  -e "app_name=<servico> app_domain=<sub>.aerobi.com.br app_port=<porta> [flags]"
```

## Cutover de apex (migração Firebase → VPS)

O apex `aerobi.com.br` (+ `www`) hoje aponta para o Firebase App Hosting (`35.219.200.207`). Virar o
A para a VPS exige cuidado: o Certbot só emite o cert com o domínio já resolvendo para `187.127.6.20`,
mas virar antes do container estar de pé derruba a produção.

Passos **manuais no painel** (a parte automatizável — vhost/SSL — está em
[`DEPLOY_APP.md → Cutover de apex`](DEPLOY_APP.md#cutover-de-apex-migração-de-provedor--vps)):

1. **~1h antes:** editar o A de `aerobi.com.br` e `www`, baixar TTL `3600 → 60` (rollback rápido).
2. No momento do cutover (com o vhost só-HTTP já criado e o container de pé): trocar o **Dados** do A de
   `35.219.200.207 → 187.127.6.20` para o apex e o `www`. Publicar a zona.
3. Validar propagação (`dig +short aerobi.com.br @1.1.1.1 → 187.127.6.20`) antes de emitir o cert.

**Rollback:** reverter o A para `35.219.200.207`. Com TTL 60, volta em minutos.

## NS / autoritativo

A zona `aerobi.com.br` usa os nameservers do próprio Registro.br (default ao registrar). Para confirmar:

```bash
dig NS aerobi.com.br +short
# Esperado: a.dns.br., b.dns.br., c.dns.br. (ou similares do Registro.br)
```

Mover para nameservers de terceiros (Cloudflare, Hostinger, etc) é possível mas **fora do escopo deste runbook** — exigiria editar NS no painel + replicar a zona inteira no novo provedor.

## Anti-padrões

❌ **Apontar para `localhost` / `127.0.0.1`** — cert não emite, Internet não resolve.

❌ **Usar CNAME para `aerobi.com.br` raiz** — `aerobi.com.br` em si precisa de A (não pode CNAME no apex). Subdomínios podem usar CNAME se for útil (não é o caso atual).

❌ **TTL muito alto** (>14400) sem motivo — dificulta corrigir mudanças. TTL `3600` é o sweet spot.

❌ **Esquecer de validar com `dig` antes de rodar Certbot** — falha do challenge HTTP-01 polui logs do Let's Encrypt e contribui para rate-limit (50 emissões/semana por domínio raiz).

## Quando reconsiderar

Se a operação crescer e exigir DNS programático (criar/remover registros via API):

- **Hostinger** tem MCP/API para DNS, mas o domínio precisaria ser transferido para lá (custo + janela de transferência).
- **Cloudflare** tem API gratuita; basta apontar NS do Registro.br para Cloudflare. Permite Terraform/Ansible.
- **route53** se já houver presença AWS.

Por enquanto (~6 subdomínios, mudanças raras), painel manual + validação `dig` é suficiente.
