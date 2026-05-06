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
| 3010 | Vaultwarden | `127.0.0.1` | Apenas via Nginx em `vault.aerobi.com.br` |
| 3333 | aerobi-api | `127.0.0.1` | Apenas via Nginx em `api.aerobi.com.br` |
| 5432 | PostgreSQL 17 | `127.0.0.1` | Apps via rede docker `warpgate`; admin via SSH tunnel |
| 8080 | Headscale | `127.0.0.1` | Apenas via Nginx em `headscale.aerobi.com.br` |

## Tailscale / Headscale

A interface `tailscale0` aceita todo tráfego entrante por padrão (`ufw_allow_tailscale_interface: true`). Confiamos nas ACLs do Headscale para controlar quem fala com quem na tailnet — não precisamos abrir porta a porta.

ACL inicial em `roles/headscale/templates/acl.json.j2`:

- `tag:dev` → `*` (laptops/celulares acessam tudo)
- `tag:vps` → `tag:airfield` (backend acessa câmeras de aeródromos)
- Tudo o mais é negado por padrão (Headscale ACL é deny-by-default fora do que está listado)

## Vaultwarden /admin

A partir da issue #5, `vault.aerobi.com.br/admin` exige cliente na tailnet (`100.64.0.0/10`). Login `/` continua público para extensão Bitwarden e app mobile. ACL implementada via Nginx `allow/deny` em `roles/vaultwarden/templates/vhost.conf.j2`.
