# Acesso ao PostgreSQL via DBeaver

## Por que SSH Tunnel?

A porta 5432 do PostgreSQL **não está aberta no firewall** da VPS.
Isso é intencional — expor banco de dados diretamente na internet é um risco de segurança grave.

O DBeaver conecta via **SSH Tunnel**: ele abre um túnel SSH seguro até a VPS
e acessa o banco como se estivesse rodando localmente.

```
DBeaver (sua máquina)
    └── SSH Tunnel (porta 22) --> VPS
                                    └── localhost:5432 --> PostgreSQL
```

---

## Configuração no DBeaver

### Passo 1 — Criar nova conexão PostgreSQL

1. Abra o DBeaver
2. Clique em **"Nova Conexão"** (ícone de plug)
3. Selecione **PostgreSQL**
4. Clique em **Próximo**

### Passo 2 — Aba "Principal"

| Campo | Valor |
|---|---|
| Host | `localhost` |
| Port | `5432` |
| Database | `postgres` |
| Username | `postgres` |
| Password | *(senha do vault)* |

### Passo 3 — Aba "SSH"

1. Marque **"Usar túnel SSH"**

| Campo | Valor |
|---|---|
| Host/IP | `195.200.1.191` (IP da VPS) |
| Port | `22` |
| User Name | `deploy` |
| Método de autenticação | `Chave pública` |
| Chave privada | `~/.ssh/id_ed25519` |

2. Clique em **"Testar túnel"** — deve mostrar "Conectado"

### Passo 4 — Testar e salvar

1. Clique em **"Testar conexão"**
2. Se aparecer "Conectado" — clique em **"Concluir"**

---

## Criar databases para cada aplicação

Após conectar no DBeaver, crie um banco para cada app:

```sql
-- Criar banco para Viki Assistant
CREATE DATABASE viki_assistant;

-- Criar banco para Barber Shop
CREATE DATABASE barber_shop;

-- Criar usuário específico por app (boa prática)
CREATE USER viki_user WITH PASSWORD 'senha_segura';
GRANT ALL PRIVILEGES ON DATABASE viki_assistant TO viki_user;
```

---

## Conectar apps ao PostgreSQL via rede Docker

As aplicações que rodam na mesma rede Docker (`warpgate`) se conectam
usando o **nome do container** como hostname:

```env
# No .env de qualquer app na rede warpgate:
DATABASE_URL=postgresql://postgres:senha@postgres:5432/nome_do_banco
#                                              ^^^^^^^
#                                     nome do container (hostname interno)
```

---

## Atualizar a senha do PostgreSQL

A senha está no Ansible Vault. Para alterar:

```bash
# Editar o vault
EDITOR=nano ansible-vault edit inventory/prod/group_vars/vault.yml \
  --vault-password-file ~/.ansible-vault/prod

# Reaplicar na VPS
ansible-playbook -i inventory/prod playbooks/setup_database.yml
```
