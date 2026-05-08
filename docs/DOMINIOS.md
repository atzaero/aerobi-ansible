# Convenção de domínios

Padrão para nomear endpoints públicos da VPS aerobi. Diferente de projetos com software-house separada do produto: aqui **toda a infra e todos os apps vivem em `aerobi.com.br`**. A distinção é semântica (categoria do subdomínio), não de domínio raiz.

## Regra

| Categoria | Subdomínio começa com | Exemplos |
|---|---|---|
| **Produto** (apps de negócio) | `api.`, `app.`, `admin.` | `api.aerobi.com.br`, `app.aerobi.com.br` |
| **Infra compartilhada** | `vault.`, `s3.`, `headscale.`, `status.` | `vault.aerobi.com.br`, `s3.aerobi.com.br` |
| **Infra admin-only (tailnet)** | `s3-console.`, `status.` | acessível só via `tailscale up` |

## Por que separar (mesmo no domínio único)

1. **Clareza no DNS**: olhar a tabela do Registro.br e saber em segundos se cada subdomínio é produto, infra ou admin.
2. **Política de exposição**: subdomínios admin (`s3-console`, `status`) ficam **tailnet-only** (range CGNAT `100.64.0.0/10` via nginx `allow/deny`). Mesmo padrão de `vault.aerobi.com.br/admin`.
3. **Auditoria**: se aparecer um subdomínio fora dessa convenção, é candidato a investigar — pode ser deploy esquecido, registro órfão, vetor de phishing.

## Lista atual

Subdomínios em `aerobi.com.br` apontando para `187.127.6.20`:

| Subdomínio | Categoria | Serviço | Porta interna | Exposição | Provisionado por |
|---|---|---|---|---|---|
| `api.aerobi.com.br` | produto | `aerobi-api` | 3333 | público | `setup_app.yml` |
| `vault.aerobi.com.br` | infra | Vaultwarden | 3010 | público (`/admin` tailnet-only) | `setup_vaultwarden.yml` |
| `headscale.aerobi.com.br` | infra | Headscale | 8080 | público (necessário para clients off-tailnet logarem) | `setup_headscale.yml` |
| `s3.aerobi.com.br` | infra | MinIO API | 9000 | público | `setup_minio.yml` + `setup_app.yml` (`vhost_client_max_body_size=25m`) |
| `s3-console.aerobi.com.br` | infra admin | MinIO Console | 9001 | **tailnet-only** | `setup_minio.yml` + `setup_app.yml` (`vhost_websocket_enabled=true vhost_tailnet_only=true`) |
| `status.aerobi.com.br` | infra admin | Uptime Kuma | 3001 | **tailnet-only** | `setup_uptime_kuma.yml` + `setup_app.yml` (`vhost_websocket_enabled=true vhost_tailnet_only=true`) |

DNS criado no Registro.br. Procedimento detalhado em [`REGISTRO_BR.md`](REGISTRO_BR.md).

## Padrão de proteção tailnet

Endpoints administrativos (criação/edição de buckets, monitores, configs) **não devem** ficar expostos publicamente. O padrão da plataforma:

1. Container exposto apenas em `127.0.0.1` (regra geral, todos os serviços).
2. Vhost nginx criado via `setup_app.yml` (com TLS via Certbot).
3. Bloco `allow 100.64.0.0/10; allow 127.0.0.1; deny all;` no `location /` — adicionado pela flag `vhost_tailnet_only=true` no template `roles/nginx_vhost/templates/vhost.conf.j2`.
4. Admin acessa via `tailscale up` em laptop conectado ao Headscale (`https://headscale.aerobi.com.br`).

Resultado: a request externa retorna `403 Forbidden`, request interna ou via tailnet retorna `200 OK`.

Mesmo padrão usado em `vault.aerobi.com.br/admin` (path-level), aplicado aqui em vhost-level para serviços inteiros admin-only.

## Adicionar um serviço de infra novo

Sequência (exemplo: Grafana em `monitoring.aerobi.com.br`):

1. **DNS no Registro.br** (ver [`REGISTRO_BR.md`](REGISTRO_BR.md)): `monitoring → A → 187.127.6.20`. Aguardar propagação (`dig +short monitoring.aerobi.com.br @1.1.1.1`).

2. **Inventory**: definir o domínio em `inventory/prod/group_vars/all/all.yml`:
   ```yaml
   grafana_domain: monitoring.aerobi.com.br
   ```

3. **Role + playbook**: criar `roles/grafana/` e `playbooks/setup_grafana.yml`. Container deve subir em `127.0.0.1` apenas.

4. **Vhost público + TLS**: rodar `setup_app.yml` parametrizado:
   ```bash
   # Se for admin-only:
   ansible-playbook playbooks/setup_app.yml \
     -e "app_name=grafana app_domain=monitoring.aerobi.com.br app_port=3030 vhost_tailnet_only=true"

   # Se for público:
   ansible-playbook playbooks/setup_app.yml \
     -e "app_name=grafana app_domain=monitoring.aerobi.com.br app_port=3030"
   ```

5. **Atualizar este doc** com a entrada na tabela "Lista atual" (e [`PORTAS.md`](PORTAS.md) com a porta).

## Anti-padrões

❌ **Bind direto em IP público:**
```
docker run -p 0.0.0.0:9000:9000 minio   # NÃO — exposto sem nginx/TLS
```

❌ **Usar IP literal no vhost:**
```
vault.187.127.6.20   # NÃO — Let's Encrypt não emite cert para IP
```

❌ **Endpoint admin público sem `vhost_tailnet_only`:**
```
admin.api.aerobi.com.br → backend admin sem allow/deny   # NÃO
```

❌ **Misturar domínio do produto com domínio pessoal:**
```
api.aerobi.com.br + portfolio.eleram.dev na mesma role/inventory   # NÃO
# Mantenha pessoal separado num inventory/repo próprio.
```

✅ **Padrão correto:**
```
api.aerobi.com.br                    público
vault.aerobi.com.br                  público + /admin tailnet-only
s3-console.aerobi.com.br             tailnet-only
status.aerobi.com.br                 tailnet-only
```

## Quando reconsiderar

Se a aerobi crescer para ponto de hospedar produtos de **clientes terceiros** (não da aerobi), avaliar domínio dedicado de infra (ex: `aerobi-infra.com.br`). Isso isola completamente o blast radius de expiração do domínio raiz e permite separar billing/SSL/SLA. Por enquanto (1 produto + infra), `aerobi.com.br` único é simples e funciona.
