# Role: uptime_kuma

Sobe [Uptime Kuma](https://github.com/louislam/uptime-kuma) (status page + monitoring self-hosted) em container Docker. Alternativa ao UptimeRobot/Pingdom — interface web moderna, suporta HTTP, TCP, ping, TLS expiry e **domain expiry**.

## Por que importa

A feature **Domain Name Expiry** dispara alerta N dias antes do domínio expirar — defesa baixa-fricção contra um modo de falha clássico (esquecer renovação de domínio derruba todos os subdomínios e quebra a confiança da plataforma).

Também monitora os outros serviços da VPS: Vaultwarden, MinIO, Headscale, Postgres, certificados TLS, etc.

## Pré-requisitos

| Role | Por quê |
|---|---|
| `docker` + `docker_network` | Container + rede `warpgate` |

## Variáveis principais

Defaults em `defaults/main.yml`. Sem default (obrigatória):

| Var | Onde definir |
|---|---|
| `uptime_kuma_domain` | `inventory/<env>/group_vars/all/all.yml` |

Comuns sobrescrevidas:

| Var | Default | Descrição |
|---|---|---|
| `uptime_kuma_version` | `2.2.1` | Pin da imagem (revisar changelog antes de bumpar) |
| `uptime_kuma_port` | `3001` | Porta no host (em `127.0.0.1`) |

## Sequência de onboard

```bash
# 1. Container Uptime Kuma
ansible-playbook playbooks/setup_uptime_kuma.yml

# 2. Vhost tailnet-only + TLS — vhost_websocket_enabled é obrigatório
#    (UI usa WebSocket pra live updates dos monitores).
#    vhost_tailnet_only restringe ao range CGNAT da Headscale: admin
#    acessa via `tailscale up` em laptop.
ansible-playbook playbooks/setup_app.yml \
  -e "app_name=uptime_kuma app_domain=status.aerobi.com.br \
      app_port=3001 vhost_websocket_enabled=true vhost_tailnet_only=true"
```

Pré-requisito do passo 2: DNS `status.aerobi.com.br` apontando para o IP da VPS (Let's Encrypt valida via HTTP-01 — funciona mesmo com `vhost_tailnet_only` porque o ACME challenge bate na porta 80 antes do bloco `allow/deny` ser instalado).

## Primeiro acesso

1. Conectar à tailnet (`tailscale up` no laptop).
2. Abrir `https://status.aerobi.com.br`.
3. **Criar conta admin** — primeira request abre form de signup. Só roda **1 vez** — depois disso, signup público fica bloqueado automaticamente.
4. Configurar monitores via UI (ver seção abaixo).
5. Configurar canal de notificação (Telegram, Discord, email, etc).

## Monitores recomendados (aerobi)

Adicionar via UI após primeiro login:

| Tipo | Alvo | Por quê |
|---|---|---|
| **Domain Name Expiry** | `aerobi.com.br` | Avisa antes de expirar — modo de falha clássico |
| **HTTP(s) público** | `https://api.aerobi.com.br`, `https://vault.aerobi.com.br`, `https://headscale.aerobi.com.br`, `https://s3.aerobi.com.br` | Verifica que serviços públicos respondem |
| **HTTP(s) tailnet-only** | `https://s3-console.aerobi.com.br`, `https://status.aerobi.com.br` | Só acessível via tailnet — VPS está na tailnet, então monitor funciona |
| **TLS Certificate Expiry** | mesmos endpoints HTTPS | Redundância sobre auto-renew do Certbot |
| **TCP** | `postgres:5432`, `valkey:6379`, `minio:9000`, `vaultwarden:80`, `headscale:8080` (via rede `warpgate`) | Saúde dos serviços internos |
| **Push Monitor** | jobs de cron (backups futuros) | Ping do job → se não chegar em N min, alerta |

## Notificações

Suporta 90+ providers via UI. Recomendados:

- **Telegram**: bot grátis, fácil setup, funciona no celular. Criar via [@BotFather](https://t.me/BotFather) e configurar token + chat_id na UI.
- **Discord**: webhook simples se já usa servidor Discord.
- **ntfy**: self-hosted ou via ntfy.sh, push notif sem app dedicado.
- **Email (SMTP)**: se já tem SMTP configurado pra outras coisas (ex: o mesmo `smtp.gmail.com` usado pelo Vaultwarden).

## Backup

Volume Docker nomeado `uptime_kuma_data` (SQLite + uploads). Backup:

```bash
ssh deploy@187.127.6.20 "docker run --rm \
  -v uptime_kuma_data:/data \
  -v \$PWD:/backup \
  alpine tar czf /backup/uptime-kuma-\$(date +%F).tgz -C /data ."
```

Automatizar via cron + upload pra MinIO bucket `aerobi-prod-backups` vira issue futura (compartilhada com backup do Postgres/Valkey).

## Status page pública (opcional)

Por default o Uptime Kuma exige login pra ver os monitores. Se quiser expor uma status page **pública** (sem login):

1. Login → Settings → **Status Pages** → Add New Status Page
2. Definir slug (ex: `public`) → ficaria em `https://status.aerobi.com.br/status/public`

⚠️ **Mas o vhost é tailnet-only** — então a status page pública não fica acessível externamente. Para ter status page pública de verdade, criar segundo vhost (`status-public.aerobi.com.br`) sem `vhost_tailnet_only` e configurar a página lá. Fora de escopo da role.

## Troubleshooting

| Sintoma | Causa provável | Fix |
|---|---|---|
| `403 Forbidden` no domínio | Sem tailscale (vhost tailnet-only) | `tailscale up` no laptop antes de abrir |
| `502 Bad Gateway` | Container não healthy | `docker logs uptime_kuma` — checar se SQLite inicializou |
| Live updates não chegam | Vhost sem `vhost_websocket_enabled` | Reaplicar `setup_app.yml` com a flag |
| Signup form não aparece | Já tem conta criada anteriormente | Login normal — signup só roda 1x. Se esqueceu senha, ver [docs upstream](https://github.com/louislam/uptime-kuma/wiki/Reset-Password) |
| Monitor TCP em rede Docker falha | Tentando `127.0.0.1:porta` em vez do hostname Docker | Usar `postgres`, `valkey`, `minio` (nomes na rede `warpgate`) |
