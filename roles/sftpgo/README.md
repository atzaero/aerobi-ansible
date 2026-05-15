# Role: sftpgo

Sobe [SFTP Go](https://github.com/drakkan/sftpgo) (servidor SFTP em Go com web admin) em container Docker. Data provider SQLite local, bind tailnet-only.

## Por que importa

Servidor SFTP isolado do `sshd` do sistema, com **web admin para gerenciar users sem editar `/etc/passwd`**. Cada user tem:

- Chroot automático no `home dir` (`/var/lib/sftpgo/users/<user>/`) — não enxerga o resto do filesystem.
- Quotas, rate-limits e filtros por IP/horário configuráveis pela UI.
- Auth por senha **ou** chave pública SSH (gerenciada pela UI, não pelo authorized_keys do sistema).
- Logs estruturados de cada conexão/upload/download (auditável).

Casos de uso na aerobi:

- **Edge do aeródromo** (Raspberry Pi, `100.64.0.9`) faz upload de gravações de câmeras IP via tailnet (`100.64.0.1:2022`) — sem expor SSH público no Raspi.
- **Troca de arquivos com integradores** (clientes terceiros que mandam manifestos, planos de voo, etc.) — basta dar tailscale + user SFTP, sem precisar criar conta no servidor.

Alternativas consideradas: `sshd` puro com chroot manual (frágil, mexer em sudoers/permissions toda vez), MinIO + cliente `mc` (S3 ≠ SFTP, integradores legados não falam S3).

## Pré-requisitos

| Role | Por quê |
| --- | --- |
| `docker` + `docker_network` | Container + rede `warpgate` |
| `tailscale_client` | Tailnet ativa para o socat sidecar escutar em `100.64.0.1` |
| `nginx` | Vhost HTTPS para o web admin |

Vault:

| Variável | Como gerar |
| --- | --- |
| `vault_sftpgo_admin_password` | `echo -n "$(openssl rand -base64 32)" \| ansible-vault encrypt_string --stdin-name 'vault_sftpgo_admin_password' --encrypt-vault-id default >> inventory/prod/group_vars/all/vault.yml` |

DNS: `sftp.aerobi.com.br → A → 187.127.6.20` no Registro.br (Let's Encrypt valida via HTTP-01).

## Variáveis principais

Defaults em `defaults/main.yml`. Sem default (obrigatórias no inventory):

| Var | Onde definir |
| --- | --- |
| `sftpgo_domain` | `inventory/<env>/group_vars/all/all.yml` |
| `sftpgo_admin_password` | mesmo arquivo, referenciando `vault_sftpgo_admin_password` |

Comumente sobrescritas:

| Var | Default | Descrição |
| --- | --- | --- |
| `sftpgo_version` | `v2.7.1` | Pin da imagem (revisar [release notes](https://github.com/drakkan/sftpgo/releases) antes de bumpar) |
| `sftpgo_http_port` | `8083` | Porta do web admin no host (`127.0.0.1`). 8080 é do Headscale. |
| `sftpgo_sftp_port` | `2022` | Porta SFTP no host (`127.0.0.1`) — proxy socat expõe em `100.64.0.1` |
| `sftpgo_log_level` | `info` | `debug` \| `info` \| `warn` \| `error` |

## Sequência de onboard

```bash
# 1. Container SFTP Go + sidecar socat tailnet
ansible-playbook playbooks/setup_sftpgo.yml

# 2. Vhost tailnet-only + TLS
#    vhost_websocket_enabled é necessário (web admin usa WS para live log tail)
#    vhost_client_max_body_size=5g cobre uploads grandes (gravações de câmeras)
ansible-playbook playbooks/setup_app.yml \
  -e "app_name=sftpgo app_domain=sftp.aerobi.com.br app_port=8083 \
      vhost_websocket_enabled=true vhost_tailnet_only=true \
      vhost_client_max_body_size=5g"
```

## Primeiro acesso (setup do admin)

1. Conectar à tailnet (`tailscale up` no laptop).
2. Pegar a senha do vault:
   ```bash
   ansible localhost -m debug -a "var=vault_sftpgo_admin_password" \
     -e "@inventory/prod/group_vars/all/vault.yml" --connection=local
   ```
3. Abrir `https://sftp.aerobi.com.br/web/admin/setup` no browser.
4. Preencher:
   - **Username**: `admin`
   - **Email**: `eleram@protonmail.com` (mesmo do `deploy_email`)
   - **Password**: output do passo 2
5. Após salvar, login normal em `https://sftp.aerobi.com.br/web/admin`.

> ⚠️ O wizard `/web/admin/setup` só responde **enquanto não houver admin cadastrado**. Após criar, o endpoint retorna 404 — login é só pelo `/web/admin`.

## Criar usuário SFTP

Via UI (`https://sftp.aerobi.com.br/web/admin/users`):

1. **Add user** (canto superior direito).
2. Campos mínimos:
   - **Username**: ex `edge-aerodromo-mvp`
   - **Status**: Active
   - **Password**: gerar com `openssl rand -base64 24` (ou marcar "only public key auth")
   - **Public keys** (opcional): colar a chave pública do cliente
   - **Home dir**: deixar em branco → SFTP Go cria `/var/lib/sftpgo/users/<username>/`
   - **Permissions**: marcar conforme caso de uso (ver tabela abaixo)
3. Salvar. User pode conectar imediatamente.

### Permissões comuns

| Permissão | Quando usar |
| --- | --- |
| `*` (all) | Admin/operador da equipe — full control |
| `list`, `download` | Read-only — auditoria, leitura de relatórios |
| `list`, `download`, `upload`, `overwrite` | Upload normal (sem deletar) |
| `list`, `download`, `upload`, `overwrite`, `delete` | Upload + housekeeping |

Filtros recomendados pra integradores externos:

- **Allowed IP/Mask**: range CGNAT da tailnet (`100.64.0.0/10`) para força conexão via VPN.
- **Max sessions**: limitar a 2-3 conexões simultâneas por user.
- **Bandwidth limits**: configurar se houver upload massivo previsto.

Via API REST (alternativa, ver [docs SFTP Go](https://github.com/drakkan/sftpgo/blob/main/openapi/openapi.yaml)):

```bash
# Autenticar
TOKEN=$(curl -sk -u admin:<senha> https://sftp.aerobi.com.br/api/v2/token | jq -r .access_token)

# Criar user
curl -sk -X POST https://sftp.aerobi.com.br/api/v2/users \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"username":"edge-aerodromo-mvp","password":"...","permissions":{"/":["*"]},"status":1}'
```

## Conectar (cliente)

Requer **tailscale up** no cliente (SFTP exposto só em `100.64.0.1`, não na internet).

### CLI

```bash
sftp -P 2022 edge-aerodromo-mvp@100.64.0.1
# Após auth:
sftp> ls
sftp> put gravacao-2026-05-15.mp4
sftp> exit
```

### Filezilla

| Campo | Valor |
| --- | --- |
| Host | `sftp://100.64.0.1` |
| Port | `2022` |
| Logon Type | Normal (senha) ou Key file (chave SSH) |
| User | `<username criado na UI>` |
| Password | (senha da UI) |

### rsync sobre SFTP

```bash
rsync -avz -e "ssh -p 2022" /local/path/ edge-aerodromo-mvp@100.64.0.1:remote/path/
```

> ⚠️ `rsync` por baixo usa SSH protocol (não SFTP puro). SFTP Go suporta isso porque implementa o subsystem SSH. Funciona com clientes padrão.

## Estrutura de dados

Volume Docker nomeado `sftpgo_data` montado em `/var/lib/sftpgo`:

```
/var/lib/sftpgo/
├── sftpgo.db                       # SQLite — users, configs, audit log
├── id_rsa, id_ecdsa, id_ed25519    # host keys SSH (geradas no 1º boot)
├── id_rsa.pub, id_ecdsa.pub, ...   # fingerprints — comparar no cliente
└── users/
    ├── edge-aerodromo-mvp/         # home dir do user
    │   └── (arquivos uploadados)
    └── outro-user/
```

Para inspecionar arquivos uploadados sem entrar no container:

```bash
ssh deploy@187.127.6.20 "sudo docker exec sftpgo ls -la /var/lib/sftpgo/users/"
```

## Backup

Volume contém **SQLite + host keys + uploads dos users**. Backup completo:

```bash
ssh deploy@187.127.6.20 "docker run --rm \
  -v sftpgo_data:/data \
  -v \$PWD:/backup \
  alpine tar czf /backup/sftpgo-\$(date +%F).tgz -C /data ."
```

Restore:

```bash
ssh deploy@187.127.6.20 "docker stop sftpgo && \
  docker run --rm -v sftpgo_data:/data -v \$PWD:/backup \
    alpine tar xzf /backup/sftpgo-YYYY-MM-DD.tgz -C /data && \
  docker start sftpgo"
```

> ⚠️ Restore mantém as **host keys originais** — clientes não recebem alerta "remote host key changed". Se restaurar sem as host keys (perder o backup), todos os clientes vão precisar limpar `~/.ssh/known_hosts` antes de reconectar.

Automatizar via cron + upload para MinIO bucket `aerobi-prod-backups` é issue futura (compartilhada com backup de Postgres/Vaultwarden/Uptime Kuma).

## Troubleshooting

| Sintoma | Causa provável | Fix |
| --- | --- | --- |
| `403 Forbidden` em `https://sftp.aerobi.com.br` | Sem tailscale (vhost tailnet-only) | `tailscale up` no laptop antes de abrir |
| `sftp: Connection refused` em `100.64.0.1:2022` | Sidecar socat parou | `docker ps -a \| grep sftpgo_tailnet_proxy` no servidor; `docker start sftpgo_tailnet_proxy` |
| `sftp: connection timed out` | Cliente sem tailscale up | Conectar à tailnet e tentar de novo (`tailscale status` deve mostrar `aerobi-vps`) |
| `Permission denied (publickey,password)` | User não existe, senha errada ou status `Inactive` | Conferir na UI `https://sftp.aerobi.com.br/web/admin/users` |
| `WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!` | Host keys SSH regeneradas (restore sem backup das keys, ou volume novo) | No cliente: `ssh-keygen -R "[100.64.0.1]:2022"` e tentar de novo |
| Upload trava na metade (~50%) | Vhost sem `vhost_client_max_body_size` adequado | Reaplicar `setup_app.yml` com `vhost_client_max_body_size=5g` (ou maior) |
| Web admin pede senha mesmo após login | Cookie session expirou | Re-login (default 15 min de idle) |
| `Setup admin` retorna 404 | Já existe admin cadastrado | Login normal em `/web/admin`; se esqueceu senha, ver "Reset admin" abaixo |
| Container `sftpgo` em loop `unhealthy` | SQLite corrompido (improvável) ou conflito de porta no host | `docker logs sftpgo`; conferir `ss -tlnp \| grep 8083` no host |

### Reset admin (esqueceu senha)

SFTP Go usa SQLite — não há "ansible-vault check" pra resetar via UI. Reset manual:

```bash
ssh deploy@187.127.6.20

# Backup primeiro (sempre)
docker run --rm -v sftpgo_data:/data -v "$PWD":/backup \
  alpine tar czf /backup/sftpgo-pre-reset-$(date +%F).tgz -C /data .

# Deletar admin via sqlite (parar container primeiro)
docker stop sftpgo
docker run --rm -v sftpgo_data:/data alpine \
  sh -c 'apk add --quiet sqlite && sqlite3 /data/sftpgo.db "DELETE FROM admins WHERE username=\"admin\";"'
docker start sftpgo

# Setup wizard volta a responder em /web/admin/setup
# Usar de novo a senha do vault_sftpgo_admin_password
```

### Logs em tempo real

```bash
ssh deploy@187.127.6.20 "docker logs -f sftpgo"
```

Logs estruturados em JSON — útil pra filtrar:

```bash
ssh deploy@187.127.6.20 "docker logs sftpgo 2>&1 | grep '\"level\":\"error\"'"
```

## Operações com a versão

Bump da imagem (testar antes em dev):

```bash
# 1. Conferir release notes
gh release view --repo drakkan/sftpgo
# 2. Editar roles/sftpgo/defaults/main.yml → sftpgo_version
# 3. Validar com docker manifest
docker manifest inspect drakkan/sftpgo:<nova-tag>
# 4. Aplicar em dev
ansible-playbook -i inventory/dev playbooks/setup_sftpgo.yml
# 5. Smoke test (login web, criar user dummy, upload+download)
# 6. Commit + PR + merge → aplicar em prod
```
