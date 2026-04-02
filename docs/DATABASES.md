# Provisionamento de Bancos de Dados por Aplicação

## O que faz

O playbook `setup_app_databases.yml` cria automaticamente, para cada aplicação:
- Um **banco de dados** dedicado no PostgreSQL
- Um **usuário** com acesso exclusivo àquele banco
- Os **privilégios** necessários (banco + schema public)

O PostgreSQL continua rodando em um único container Docker. Cada app usa
seu próprio banco e usuário — sem compartilhar credenciais.

---

## Como as aplicações se conectam

As apps que rodam na mesma rede Docker (`warpgate`) se conectam usando o
**nome do container** como hostname:

```env
# .env de qualquer app na rede warpgate
DATABASE_URL=postgresql://viki_user:senha@postgres:5432/viki_assistant
#                                          ^^^^^^^^
#                              hostname = nome do container (não o IP)
```

| Campo | Valor |
|---|---|
| Host | `postgres` (nome do container) |
| Porta | `5432` |
| Usuário | usuário da aplicação (ex: `viki_user`) |
| Senha | definida no Vault |
| Database | banco da aplicação (ex: `viki_assistant`) |

---

## Adicionar uma nova aplicação

### 1. Registrar a app em `group_vars`

Edite `inventory/prod/group_vars/all/all.yml` e adicione uma entrada em `postgres_apps`:

```yaml
postgres_apps:
  - name: viki_assistant       # nome legível (usado nos logs)
    db: viki_assistant         # nome do banco no PostgreSQL
    user: viki_user            # usuário PostgreSQL da app
    password: "{{ vault_viki_db_password }}"   # referência ao vault

  # Nova app:
  - name: minha_nova_app
    db: minha_nova_app
    user: minha_nova_user
    password: "{{ vault_minha_nova_db_password }}"
```

### 2. Criar a senha criptografada no Vault

```bash
# Gerar o bloco !vault para a nova senha
ansible-vault encrypt_string 'SenhaForte@2026!' \
  --name 'vault_minha_nova_db_password' \
  --vault-password-file ~/.ansible-vault/prod \
  --encrypt-vault-id default
```

Cole o bloco gerado em `inventory/prod/group_vars/all/vault.yml`:

```yaml
vault_minha_nova_db_password: !vault |
          $ANSIBLE_VAULT;1.1;AES256
          ...bloco gerado pelo comando acima...
```

### 3. Rodar o playbook

```bash
# Produção
ansible-playbook playbooks/setup_app_databases.yml

# Dev
ansible-playbook -i inventory/dev playbooks/setup_app_databases.yml
```

O playbook é **idempotente** — pode ser rodado várias vezes sem problemas.
Se o banco já existe, apenas atualiza privilégios e senha.

---

## Ambientes

### Produção (`inventory/prod`)
- Senhas definidas no Vault (criptografadas)
- Banco acessível apenas via rede Docker interna ou SSH Tunnel
- Arquivo: `inventory/prod/group_vars/all/vault.yml`

### Dev (`inventory/dev`)
- Senhas em texto claro no `all.yml` (aceitável em dev)
- PostgreSQL pode ter porta aberta no firewall para acesso direto
- Arquivo: `inventory/dev/group_vars/all/all.yml`

---

## Verificar bancos criados

Via DBeaver (SSH Tunnel) ou diretamente na VPS:

```bash
# Na VPS, listar todos os bancos
docker exec postgres psql -U postgres -c "\l"

# Listar usuários
docker exec postgres psql -U postgres -c "\du"

# Testar conexão com usuário da app
docker exec postgres psql -U viki_user -d viki_assistant -c "SELECT current_user, current_database();"
```

---

## Senhas padrão criadas

| Aplicação | Banco | Usuário | Senha (prod) |
|---|---|---|---|
| Viki Assistant | `viki_assistant` | `viki_user` | no Vault (`vault_viki_db_password`) |
| Barber Shop | `barber_shop` | `barber_user` | no Vault (`vault_barber_db_password`) |

> Para ver a senha: `ansible-vault view inventory/prod/group_vars/all/vault.yml`

---

## Ver também

- `docs/DBEAVER.md` — como conectar via DBeaver com SSH Tunnel
- `inventory/prod/group_vars/all/all.yml` — lista de apps (`postgres_apps`)
- `inventory/prod/group_vars/all/vault.yml` — senhas criptografadas
