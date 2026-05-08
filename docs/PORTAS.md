# Portas e regras de firewall

UFW na VPS Aerobi é restritivo: tudo bloqueado por padrão, apenas o que está listado abaixo é permitido.

## Portas TCP públicas

| Porta | Serviço | Acesso | Notas |
|---|---|---|---|
| 22 | SSH | Internet | CI/CD GitHub Actions e admin manual via chave |
| 80 | HTTP | Internet | Redireciona para HTTPS via Certbot |
| 443 | HTTPS | Internet | Nginx serve `api.aerobi.com.br`, `vault.aerobi.com.br`, `headscale.aerobi.com.br` |

## Portas UDP públicas

| Porta | Serviço | Acesso | Notas |
|---|---|---|---|
| 41641 | Tailscale (WireGuard) | Internet | Handshake P2P do cliente Tailscale; tráfego efetivo trafega na interface `tailscale0` |

## Portas internas (não expostas)

| Porta | Serviço | Bind | Acesso |
|---|---|---|---|
| 3001 | Uptime Kuma | `127.0.0.1` | Apenas via Nginx em `status.aerobi.com.br` (tailnet-only) |
| 3010 | Vaultwarden | `127.0.0.1` | Apenas via Nginx em `vault.aerobi.com.br` (`/admin` tailnet-only) |
| 3333 | aerobi-api | `127.0.0.1` | Apenas via Nginx em `api.aerobi.com.br` |
| 5432 | PostgreSQL 17 | `127.0.0.1` (apps) + `100.64.0.1` (tailnet via socat sidecar) | Apps via rede docker `warpgate`; admin via DBeaver direto em `100.64.0.1:5432` (sem SSH tunnel — issue #7 fechada via `roles/postgres_tailnet_proxy/`) |
| 6379 | Valkey | `127.0.0.1` | Apps via rede docker `warpgate` (sem vhost) |
| 8080 | Headscale | `127.0.0.1` | Apenas via Nginx em `headscale.aerobi.com.br` |
| 9000 | MinIO API | `127.0.0.1` | Apenas via Nginx em `s3.aerobi.com.br` (apps internos via `minio:9000` na rede docker) |
| 9001 | MinIO Console | `127.0.0.1` | Apenas via Nginx em `s3-console.aerobi.com.br` (tailnet-only) |

## Tailscale / Headscale

A interface `tailscale0` aceita todo tráfego entrante por padrão (`ufw_allow_tailscale_interface: true`). Confiamos nas ACLs do Headscale para controlar quem fala com quem na tailnet — não precisamos abrir porta a porta.

ACL inicial em `roles/headscale/templates/acl.json.j2`:

- `tag:dev` → `*` (laptops/celulares acessam tudo)
- `tag:vps` → `tag:airfield` (backend acessa câmeras de aeródromos)
- Tudo o mais é negado por padrão (Headscale ACL é deny-by-default fora do que está listado)

## Convenção de proteção via tailnet (admin-only)

Endpoints administrativos não devem ficar expostos publicamente. O padrão da plataforma é restringir o vhost ao range CGNAT da Headscale (`100.64.0.0/10`) + localhost via nginx `allow/deny`. Externo retorna 403; admin acessa via `tailscale up` em laptop.

### Endpoints atualmente tailnet-only

| URL | Por quê |
|---|---|
| `https://vault.aerobi.com.br/admin` | Painel admin do Vaultwarden — convidar usuários, configurar SMTP, etc. Login `/` continua público para extensão Bitwarden e app mobile. ACL path-level no template próprio da role vaultwarden. |
| `https://s3-console.aerobi.com.br` | Painel MinIO admin — criar/deletar buckets, gerar access keys. Vhost-level via flag `vhost_tailnet_only=true` em `setup_app.yml`. |
| `https://status.aerobi.com.br` | Painel Uptime Kuma — criar/editar monitores, canais de notificação. Vhost-level via `vhost_tailnet_only=true`. |

### Como aplicar em novo serviço admin

No `setup_app.yml`, passar `vhost_tailnet_only=true`:

```bash
ansible-playbook playbooks/setup_app.yml \
  -e "app_name=<svc> app_domain=<sub>.aerobi.com.br app_port=<porta> vhost_tailnet_only=true"
```

A flag injeta o bloco no `location /` do template `roles/nginx_vhost/templates/vhost.conf.j2`:

```nginx
allow 100.64.0.0/10;
allow 127.0.0.1;
deny all;
```

Combinar com `vhost_websocket_enabled=true` se a UI usa WebSocket (MinIO console, Uptime Kuma).
