# Acesso ao PostgreSQL via DBeaver

Existem **2 caminhos** para conectar ao Postgres da VPS aerobi a partir do DBeaver (ou `psql`/`pg_isready`):

1. **Direto via tailnet (recomendado)** — exige cliente Tailscale conectado ao Headscale. Sem SSH tunnel; conexão TCP direta ao IP da tailnet da VPS.
2. **SSH tunnel (legado)** — para máquinas que ainda não estão na tailnet.

A porta 5432 do PostgreSQL **não está aberta no firewall público** da VPS (validado: `nc 187.127.6.20 5432` → timeout). Isso é intencional — expor banco de dados na internet é risco grave.

---

## Caminho 1 — Direto via tailnet (recomendado)

### Pré-requisitos

- Tailscale instalado e logado em `https://headscale.aerobi.com.br`. Confirmar com `tailscale status` (deve listar `vps-prod` e seu device).
- Sidecar `postgres_tailnet_proxy` rodando na VPS (`ansible-playbook playbooks/setup_postgres_tailnet.yml` — issue [#7](https://github.com/atzaero/aerobi-ansible/issues/7)).

### Como funciona

```
DBeaver (laptop)
    ── tcp 5432 ──> 100.64.0.1 (VPS na tailnet)
                        └── socat (network_mode: host)
                                └── 127.0.0.1:5432 ──> postgres container
```

`socat` escuta diretamente na interface `tailscale0` da VPS (sem iptables NAT do Docker, que bypassaria o UFW). Tráfego só chega quando origina da tailnet.

### Configuração no DBeaver

#### Passo 1 — Nova conexão PostgreSQL

1. Abra o DBeaver
2. Clique em **"Nova Conexão"** (ícone de plug)
3. Selecione **PostgreSQL** → **Próximo**

#### Passo 2 — Aba "Principal"

| Campo | Valor |
|---|---|
| Host | `100.64.0.1` |
| Port | `5432` |
| Database | `postgres` (ou nome da app: `aerobi`, `vaultwarden`, etc.) |
| Username | `postgres` (ou usuário da app: `aerobi_user`, etc.) |
| Password | *(senha do vault — ver `inventory/prod/group_vars/all/vault.yml`)* |

#### Passo 3 — Aba "SSH"

**Não marque nada.** Sem SSH tunnel — tailnet já é a camada de rede privada.

#### Passo 4 — Testar e salvar

1. **Testar conexão** → deve retornar "Conectado".
2. **Concluir**.

### Linha de comando

```bash
# Pegar a senha do vault:
PGPASSWORD=$(ansible localhost -m debug -a 'var=vault_postgres_password' \
  -e "@inventory/prod/group_vars/all/vault.yml" --connection=local 2>/dev/null \
  | sed -n 's/.*"vault_postgres_password": "\(.*\)".*/\1/p')

psql -h 100.64.0.1 -U postgres -d postgres
pg_isready -h 100.64.0.1 -p 5432
```

---

## Caminho 2 — SSH tunnel (legado)

Use só se a máquina cliente ainda não está na tailnet (ex: VPS de CI/CD externa que não pode rodar tailscale).

```
DBeaver (sua máquina)
    └── SSH tunnel (porta 22) ──> 187.127.6.20
                                    └── 127.0.0.1:5432 ──> postgres
```

### Configuração

#### Passo 1 — Aba "Principal"

| Campo | Valor |
|---|---|
| Host | `localhost` |
| Port | `5432` |
| Database | `postgres` |
| Username | `postgres` |
| Password | *(senha do vault)* |

#### Passo 2 — Aba "SSH"

1. Marque **"Usar túnel SSH"**

| Campo | Valor |
|---|---|
| Host/IP | `187.127.6.20` |
| Port | `22` |
| User Name | `deploy` |
| Método de autenticação | `Chave pública` |
| Chave privada | `~/.ssh/id_ed25519` |

2. **Testar túnel** → "Conectado".

#### Passo 3 — Testar e salvar

1. **Testar conexão** → "Conectado".
2. **Concluir**.

---

## Conectar apps internos ao PostgreSQL

Apps que rodam na mesma rede Docker (`warpgate`) se conectam usando o **nome do container** como hostname — **não** via tailnet ou SSH tunnel:

```env
# .env de qualquer app na rede warpgate:
DATABASE_URL=postgresql://aerobi_user:senha@postgres:5432/aerobi
#                                            ^^^^^^^^
#                                  nome do container postgres
```

Os apps proprietários (`aerobi-api`, `vaultwarden`, `headscale`) seguem esse padrão. Tailnet/SSH tunnel são só para acesso administrativo a partir de clientes externos.

---

## Atualizar uma senha

Senhas estão no Ansible Vault. Para alterar:

```bash
# 1. Ver senha atual (validar antes de mudar):
ansible localhost -m debug -a 'var=vault_postgres_password' \
  -e "@inventory/prod/group_vars/all/vault.yml" --connection=local

# 2. Editar vault.yml (ver instruções inline no header do arquivo):
#    - Apagar bloco antigo
#    - Gerar novo:
echo -n "$(openssl rand -hex 32)" | \
  ansible-vault encrypt_string --stdin-name 'vault_postgres_password' \
  --encrypt-vault-id default \
  >> inventory/prod/group_vars/all/vault.yml
#    - Apagar bloco antigo do arquivo

# 3. Reaplicar:
ansible-playbook playbooks/setup_database.yml
ansible-playbook playbooks/setup_app_databases.yml   # se mudou senha de app
```
