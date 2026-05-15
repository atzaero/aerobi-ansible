# Bootstrap zero-to-prod da VPS aerobi

Runbook completo para provisionar a VPS Hostinger da aerobi do zero até infra funcional (Postgres + Headscale + Vaultwarden + MinIO + Valkey + Uptime Kuma + vhosts TLS).

Use este doc:

- Quando trocar/recriar a VPS de produção (ex: depois de formatar).
- Quando criar uma VPS dev nova com a mesma stack.
- Como referência para debugar onde o processo travou.

## Pré-requisitos

Antes de começar, confirmar:

- [ ] **Master vault**: `~/.ansible-vault/aerobi-prod` existe e contém a senha master. Sem ela, secrets de `vault.yml` não decriptam — playbooks falham.
- [ ] **IP da VPS**: confirmado no painel Hostinger (atualmente `187.127.6.20`). Atualizar `inventory/prod/hosts.yml → ansible_host` se mudou.
- [ ] **Chave SSH no painel Hostinger**: a chave pública correspondente a `~/.ssh/id_ed25519` foi adicionada ao painel **antes** de criar/recriar a VPS — sem isso, `ssh root@IP` falha.
- [ ] **Domínio**: `aerobi.com.br` registrado e ativo no Registro.br (`whois aerobi.com.br | grep -i status`).

## Passo 0 — DNS no Registro.br

Cada subdomínio precisa de um registro **A** apontando para o IP da VPS, **antes** de rodar Certbot (Let's Encrypt valida via HTTP-01, exige domínio resolvendo).

Procedimento detalhado: [`REGISTRO_BR.md`](REGISTRO_BR.md).

### Registros mínimos para a infra atual

| Subdomínio | Tipo | Valor | TTL |
|---|---|---|---|
| `api` | A | `187.127.6.20` | 3600 |
| `vault` | A | `187.127.6.20` | 3600 |
| `headscale` | A | `187.127.6.20` | 3600 |
| `s3` | A | `187.127.6.20` | 3600 |
| `s3-console` | A | `187.127.6.20` | 3600 |
| `status` | A | `187.127.6.20` | 3600 |
| `sftp` | A | `187.127.6.20` | 3600 |

### Validar propagação

```bash
for sub in api vault headscale s3 s3-console status sftp; do
  echo -n "$sub.aerobi.com.br → "
  dig +short "$sub.aerobi.com.br" @1.1.1.1
done
```

Cada um deve retornar `187.127.6.20`. **Não pular** — sem isso, certbot falha.

## Passo 1 — Bootstrap base da VPS

Aplica `setup_vps.yml` (cria usuário `deploy`, hardening SSH, UFW, Fail2Ban, nginx, Docker, Tailscale client). Em VPS fresh, `deploy` ainda não existe — Ansible entra como `root` na primeira execução.

### 1.1 — Limpar fingerprint antigo (se VPS foi recriada com mesmo IP)

```bash
ssh-keygen -R 187.127.6.20
```

Senão `ssh` reclama de "host key changed".

### 1.2 — Confirmar acesso SSH como root

```bash
ssh root@187.127.6.20 "echo ok"
```

Deve retornar `ok` sem pedir senha (chave já injetada pelo painel Hostinger). Se falhar, voltar e adicionar a chave no painel.

### 1.3 — Editar `inventory/prod/hosts.yml` para modo fresh

Trocar temporariamente:

```yaml
vps-prod:
  ansible_host: 187.127.6.20
  ansible_user: root          # era: deploy
  # ansible_become: true      # comentar
  # ansible_become_method: sudo
  ansible_ssh_private_key_file: ~/.ssh/id_ed25519
```

### 1.4 — Aplicar setup_vps.yml

```bash
cd /home/elvis/aerobi-projects/aerobi-ansible
ansible-playbook playbooks/setup_vps.yml
```

Tempo: ~5–8 min. Cobre: usuário deploy + chaves SSH, hardening SSH (root fica bloqueado depois), UFW (22/80/443 + UDP 41641), Fail2Ban, nginx, Docker, Tailscale client.

### 1.5 — Reverter `hosts.yml` para modo prod

Voltar para:

```yaml
vps-prod:
  ansible_host: 187.127.6.20
  ansible_user: deploy
  ansible_become: true
  ansible_become_method: sudo
  ansible_ssh_private_key_file: ~/.ssh/id_ed25519
```

### 1.6 — Validar acesso como deploy

```bash
ssh deploy@187.127.6.20 "sudo whoami"
```

Deve retornar `root` **sem pedir senha** (sudoers `NOPASSWD:ALL` configurado pelo `setup_vps.yml`). Se pedir senha, algo falhou — checar `/etc/sudoers.d/deploy` no servidor.

## Passo 2 — Plataforma de dados (Postgres)

### 2.1 — Postgres base

```bash
ansible-playbook playbooks/setup_database.yml
```

Sobe container `postgres:17` em `127.0.0.1:5432`, com senha do vault.

### 2.2 — Bancos por aplicação

```bash
ansible-playbook playbooks/setup_app_databases.yml
```

Lê `postgres_apps` do `inventory/prod/group_vars/all/all.yml` e cria DB + user para cada entrada (`aerobi`, `vaultwarden`, `headscale`).

## Passo 3 — Headscale (control plane VPN)

```bash
ansible-playbook playbooks/setup_headscale.yml
```

Sobe Headscale (versão pinada) em `127.0.0.1:8080`, conectado ao banco `headscale` no Postgres. Cria também o vhost público `headscale.aerobi.com.br` com TLS.

### 3.1 — Gerar pre-auth key para a VPS

```bash
ssh deploy@187.127.6.20 \
  'docker exec headscale headscale preauthkeys create \
     --user aerobi --reusable --expiration 90d --tags tag:vps'
```

Copiar a chave e salvar no vault:

```bash
echo -n "<key>" | \
  ansible-vault encrypt_string --stdin-name 'vault_headscale_authkey_vps' \
  --vault-id default@~/.ansible-vault/aerobi-prod \
  > /tmp/key.yml
# Editar inventory/prod/group_vars/all/vault.yml e substituir vault_headscale_authkey_vps
```

### 3.2 — Conectar a VPS à tailnet

```bash
ansible-playbook playbooks/setup_vps.yml --tags tailscale
```

A VPS aparece em `tailscale status` como `vps-prod` com IP `100.64.0.1`.

## Passo 4 — Vaultwarden (cofre de senhas)

### 4.1 — Container + vhost

```bash
ansible-playbook playbooks/setup_vaultwarden.yml
```

Sobe Vaultwarden (versão pinada — ver `roles/vaultwarden/defaults/main.yml`) em `127.0.0.1:3010`, conectado ao banco `vaultwarden` no Postgres. Cria também o vhost `vault.aerobi.com.br` com TLS e WebSocket. O endpoint `/admin` é restrito à tailnet (range CGNAT `100.64.0.0/10` via nginx `allow/deny`).

### 4.2 — Validar `/admin`

Com `tailscale up` no laptop, abrir `https://vault.aerobi.com.br/admin` no browser e fornecer o token:

```bash
ansible localhost -m debug -a "var=vault_vaultwarden_admin_token" \
  -e "@inventory/prod/group_vars/all/vault.yml" --connection=local
```

Após login: convidar primeiro usuário (signup público está off por design).

## Passo 5 — Valkey (cache + filas)

```bash
ansible-playbook playbooks/setup_valkey.yml
```

Sobe Valkey (versão pinada — ver `roles/valkey/defaults/main.yml`) em `127.0.0.1:6379`. Serviço **interno** — sem vhost público; apps acessam via rede `warpgate` usando hostname `valkey:6379`.

Pré-requisito: `vault_valkey_password` definido no vault. Se ausente, gerar:
```bash
echo -n "$(openssl rand -hex 32)" | \
  ansible-vault encrypt_string --stdin-name 'vault_valkey_password' \
  --vault-id default@~/.ansible-vault/aerobi-prod \
  >> inventory/prod/group_vars/all/vault.yml
```

## Passo 6 — MinIO (object storage)

### 6.1 — Container + buckets

Pré-requisito: `vault_minio_root_password` definido no vault (mesmo procedimento do Valkey).

```bash
ansible-playbook playbooks/setup_minio.yml
```

Sobe MinIO (versão pinada — ver `roles/minio/defaults/main.yml`) em `127.0.0.1:9000` (API) e `127.0.0.1:9001` (console). Cria buckets declarados em `minio_buckets` (`aerobi-prod-uploads`, `aerobi-prod-backups`).

### 6.2 — Vhost API S3 (público)

`vhost_client_max_body_size=25m` permite uploads > 1 MB (default nginx).

```bash
ansible-playbook playbooks/setup_app.yml \
  -e "app_name=minio_api app_domain=s3.aerobi.com.br \
      app_port=9000 vhost_client_max_body_size=25m"
```

### 6.3 — Vhost console (tailnet-only)

`vhost_websocket_enabled=true` é **obrigatório** — o object browser do console usa WebSocket. `vhost_tailnet_only=true` restringe a tailnet (admin-only).

```bash
ansible-playbook playbooks/setup_app.yml \
  -e "app_name=minio_console app_domain=s3-console.aerobi.com.br \
      app_port=9001 vhost_websocket_enabled=true vhost_tailnet_only=true"
```

## Passo 7 — Uptime Kuma (monitoring + status page)

### 7.1 — Container

```bash
ansible-playbook playbooks/setup_uptime_kuma.yml
```

### 7.2 — Vhost (tailnet-only com WebSocket)

```bash
ansible-playbook playbooks/setup_app.yml \
  -e "app_name=uptime_kuma app_domain=status.aerobi.com.br \
      app_port=3001 vhost_websocket_enabled=true vhost_tailnet_only=true"
```

Após apply, com `tailscale up` no laptop, abrir `https://status.aerobi.com.br` **imediatamente** (signup só roda 1× — depois é bloqueado). Em seguida, configurar monitores via UI:

- **Domain Name Expiry** → `aerobi.com.br` (primeiro monitor a criar — defesa contra esquecimento de renovação).
- HTTPS, TCP, TLS expiry — ver `roles/uptime_kuma/README.md` → "Monitores recomendados".

## Passo 8 — App de produto (aerobi-api)

```bash
ansible-playbook playbooks/setup_app.yml \
  -e "app_name=aerobi_api app_domain=api.aerobi.com.br app_port=3333"
```

Cria vhost + cert para `api.aerobi.com.br`. O container `aerobi-api` em si é deployado via GitHub Actions (fora do escopo deste runbook).

## Passo 9 — SFTP Go (file transfer tailnet-only)

Pré-requisito: `vault_sftpgo_admin_password` definido no vault (mesmo procedimento do Valkey):

```bash
echo -n "$(openssl rand -base64 32)" | \
  ansible-vault encrypt_string --stdin-name 'vault_sftpgo_admin_password' \
  --vault-id default@~/.ansible-vault/aerobi-prod \
  >> inventory/prod/group_vars/all/vault.yml
```

### 9.1 — Container + sidecar socat tailnet

```bash
ansible-playbook playbooks/setup_sftpgo.yml
```

Sobe SFTP Go (versão pinada — ver `roles/sftpgo/defaults/main.yml`) em `127.0.0.1:8083` (web admin) e `127.0.0.1:2022` (SFTP). Sidecar socat expõe SFTP em `100.64.0.1:2022` via tailnet (mesmo padrão do `postgres_tailnet_proxy`).

### 9.2 — Vhost (tailnet-only com WebSocket)

`vhost_client_max_body_size=5g` cobre uploads grandes (gravações de câmeras do edge).

```bash
ansible-playbook playbooks/setup_app.yml \
  -e "app_name=sftpgo app_domain=sftp.aerobi.com.br app_port=8083 \
      vhost_websocket_enabled=true vhost_tailnet_only=true \
      vhost_client_max_body_size=5g"
```

### 9.3 — Setup do admin (one-time)

Com `tailscale up` no laptop, abrir `https://sftp.aerobi.com.br/web/admin/setup` e fornecer a senha:

```bash
ansible localhost -m debug -a "var=vault_sftpgo_admin_password" \
  -e "@inventory/prod/group_vars/all/vault.yml" --connection=local
```

User `admin`, email do `deploy_email`. Após criar, o endpoint `/setup` retorna 404 — login normal em `/web/admin`.

Próximos passos (criar users SFTP, conectar via Filezilla/CLI, backup): ver [`roles/sftpgo/README.md`](../roles/sftpgo/README.md).

## Passo 10 — Validação final

### 10.1 — Containers rodando

```bash
ssh deploy@187.127.6.20 "docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'"
```

Esperado:

```
NAMES                   STATUS          PORTS
postgres                Up X (healthy)  127.0.0.1:5432->5432
postgres_tailnet_proxy  Up X (healthy)
headscale               Up X (healthy)  127.0.0.1:8080->8080
vaultwarden             Up X (healthy)  127.0.0.1:3010->80/tcp
valkey                  Up X (healthy)  127.0.0.1:6379->6379
minio                   Up X (healthy)  127.0.0.1:9000->9000, 127.0.0.1:9001->9001
uptime_kuma             Up X (healthy)  127.0.0.1:3001->3001
sftpgo                  Up X (healthy)  127.0.0.1:8083->8080, 127.0.0.1:2022->2022
sftpgo_tailnet_proxy    Up X (healthy)
aerobi-api              Up X (healthy)  127.0.0.1:3333->3333
```

Containers com `network_mode: host` (postgres_tailnet_proxy, sftpgo_tailnet_proxy) não mostram mapeamento de portas — escutam direto na interface `tailscale0` do host.

Se algum não estiver `healthy`: `docker logs <nome>` no servidor para triar.

### 10.2 — TLS + exposição correta

```bash
# Públicos (esperar 200/redirect):
for url in https://api.aerobi.com.br \
          https://vault.aerobi.com.br \
          https://headscale.aerobi.com.br \
          https://s3.aerobi.com.br/minio/health/live; do
  echo -n "$url → "
  curl -sI "$url" | head -1
done

# Tailnet-only (sem tailscale → 403):
for url in https://s3-console.aerobi.com.br \
          https://status.aerobi.com.br \
          https://sftp.aerobi.com.br; do
  echo -n "$url (sem tailscale) → "
  curl -sI "$url" | head -1
done
```

Com `tailscale up` no laptop, repetir os tailnet-only — devem retornar 200/302.

### 10.3 — Tailnet (SFTP + Postgres via socat)

Da máquina dev com `tailscale up`:

```bash
# Postgres acessível via tailnet
pg_isready -h 100.64.0.1 -p 5432

# SFTP Go acessível via tailnet (espera prompt de senha do admin do SFTP Go)
nc -zv 100.64.0.1 2022
```

## Troubleshooting

| Sintoma | Causa provável | Fix |
|---|---|---|
| `ssh root@<ip>` pede senha | Chave SSH não injetada | Adicionar pubkey no painel Hostinger antes de iniciar |
| `setup_vps.yml` falha em "Adicionar chaves SSH autorizadas" | Inventory ainda em modo `deploy` numa VPS fresh | Editar `hosts.yml` para `ansible_user: root` (Passo 1.3) |
| Próximo playbook após `setup_vps` pede senha sudo | Inventory ainda em modo `root` | Reverter `hosts.yml` para `deploy` + `become: true` (Passo 1.5) |
| `setup_app.yml` falha em certbot | DNS não propagou | `dig +short <subdomain> @1.1.1.1` e aguardar |
| Vaultwarden retorna 502 | Container não conectou ao postgres | `docker logs vaultwarden` — provável senha errada (regerou DB sem regerar container) |
| `/admin` do Vaultwarden retorna 403 | Sem tailscale | `tailscale up` no laptop |
| s3-console fica em loading loop | Vhost sem `vhost_websocket_enabled` | Reaplicar `setup_app.yml` com a flag |
| `sftp: Connection refused` em `100.64.0.1:2022` | Container `sftpgo_tailnet_proxy` parado ou VPS off-tailnet | `docker ps` no servidor; conferir `tailscale status` |
| Upload SFTP grande trava em ~50% | Vhost sem `vhost_client_max_body_size=5g` (afeta API REST do SFTP Go) | Reaplicar `setup_app.yml` com a flag |
| Decryption falha (`VAULT_FAILED`) | Master errada em `~/.ansible-vault/aerobi-prod` | Conferir master correta |

Para incidentes mais sérios (suspeita de comprometimento, comportamento estranho), ver [`INCIDENT_RESPONSE.md`](INCIDENT_RESPONSE.md).

## O que NÃO está coberto aqui

- Deploy do app `aerobi-api` em si (build + push da imagem) — feito via GitHub Actions de [`atzaero/aerobi-api`](https://github.com/atzaero/aerobi-api). `setup_app.yml` cria só o vhost.
- Backup automatizado do Postgres + volumes (issue futura — backup para `aerobi-prod-backups` no MinIO).
- Postgres acessível via tailnet sem SSH tunnel (issue [#7](https://github.com/atzaero/aerobi-ansible/issues/7) — Docker bypassa UFW). Mesma técnica usada no SFTP Go (`roles/sftpgo_tailnet_proxy/`).
- Aerodrome edge (Raspberry Pi como subnet router Tailscale) — separado em `playbooks/setup_aerodrome.yml`.
- Replicação/HA — fora de escopo do baseline.
