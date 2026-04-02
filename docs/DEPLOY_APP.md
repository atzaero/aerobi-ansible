# Deploy de Aplicações

Este documento explica como subir uma nova aplicação no servidor usando o Ansible e GitHub Actions.

## Visão geral

O Ansible cuida da **infraestrutura** (uma vez por aplicação):
- Criação do registro DNS apontando para o servidor
- Provisionamento do banco de dados PostgreSQL (se necessário)
- Criação do diretório da app no servidor
- Configuração do virtual host Nginx (reverse proxy)
- Emissão do certificado SSL via Let's Encrypt

O **GitHub Actions** cuida do deploy contínuo (a cada release):
- Build da imagem Docker
- Publicação no GitHub Container Registry (GHCR)
- Transferência do `.env` e `docker-compose.prod.yml` para o servidor
- Execução do `docker compose up -d`

---

## Pré-requisitos

Antes de começar, certifique-se de que:

1. `setup_vps.yml` já foi executado (Nginx instalado)
2. As portas 80 e 443 estão abertas no firewall (já configurado)

---

## Passo a passo para uma nova aplicação

### 1. Escolha uma porta interna

Cada aplicação precisa de uma porta diferente no servidor. Controle quais estão em uso:

| Aplicação         | Domínio               | Porta |
|-------------------|-----------------------|-------|
| elvisea_portfolio | elvisea.dev           | 3003  |
| viki_assistant    | (a definir)           | 3001  |
| barber_shop       | (a definir)           | 3002  |
| aerobi            | aerobi.elvisea.dev    | 3333  |

### 2. Crie o registro DNS

Aponte o domínio/subdomínio para o IP do servidor (`195.200.1.191`) via MCP da Hostinger ou painel de DNS.

Usando o MCP (Claude Code):
```
criar registro DNS: <subdominio>.elvisea.dev → A → 195.200.1.191
```

Aguarde a propagação antes de executar o playbook (necessário para emissão do SSL).

### 3. Provisione o banco de dados (se a app usar PostgreSQL)

Adicione a app em `inventory/prod/group_vars/all/all.yml`, na seção `postgres_apps`:

```yaml
postgres_apps:
  - name: nome_da_app
    db: nome_da_app
    user: nome_user
    password: "{{ vault_nome_da_app_db_password }}"
```

Adicione a senha no vault:

```bash
ansible-vault edit inventory/prod/group_vars/all/vault.yml
```

Execute o playbook de bancos:

```bash
ansible-playbook playbooks/setup_app_databases.yml
```

### 4. Execute o playbook `setup_app.yml`

```bash
cd /home/elvis/projects/ansible-vps
source .venv/bin/activate

ansible-playbook playbooks/setup_app.yml \
  -e "app_name=nome_da_app app_domain=dominio.com app_port=3001"
```

**Parâmetros:**

| Parâmetro    | Descrição                              | Exemplo                  |
|--------------|----------------------------------------|--------------------------|
| `app_name`   | Identificador único, sem espaços       | `aerobi`                 |
| `app_domain` | Domínio público apontando pro servidor | `aerobi.elvisea.dev`     |
| `app_port`   | Porta interna do container Docker      | `3333`                   |

**Exemplo para o aerobi:**

```bash
ansible-playbook playbooks/setup_app.yml \
  -e "app_name=aerobi app_domain=aerobi.elvisea.dev app_port=3333"
```

O playbook irá:
- Criar `/home/deploy/apps/aerobi/`
- Criar `/etc/nginx/sites-available/aerobi`
- Habilitar o site e recarregar o Nginx
- Emitir o certificado SSL via Certbot (Let's Encrypt)

### 5. Configure o `docker-compose.prod.yml` da aplicação

A aplicação precisa expor a porta apenas em `localhost`. Exemplo:

```yaml
services:
  minha_app:
    image: ${REGISTRY}/${IMAGE_NAME}:latest
    ports:
      - "127.0.0.1:3001:3001"   # nunca "3001:3001" (expõe para internet)
    networks:
      - warpgate

networks:
  warpgate:
    external: true
```

### 6. Configure os GitHub Secrets no repositório da aplicação

Acesse `Settings → Secrets and variables → Actions` e adicione:

| Secret            | Valor                                   |
|-------------------|-----------------------------------------|
| `SSH_PRIVATE_KEY` | Chave privada `github-actions-cicd`     |
| `REMOTE_USER`     | `deploy`                                |
| `REMOTE_TARGET`   | `/home/deploy/apps/<app_name>`          |
| `REMOTE_HOST`     | `195.200.1.191`                         |
| `REMOTE_PORT`     | `22`                                    |
| + demais vars     | Variáveis específicas da aplicação      |

> A `SSH_PRIVATE_KEY` é compartilhada entre todos os projetos.
> Se precisar regerar, consulte o README principal.

### 7. Publique uma release para disparar o deploy

O pipeline do GitHub Actions é disparado ao publicar uma release. Ele irá automaticamente:
1. Fazer build da imagem Docker
2. Publicar no GitHub Container Registry (GHCR)
3. Conectar ao servidor via SSH
4. Transferir o `.env` e o `docker-compose.prod.yml`
5. Executar `docker compose up -d`

---

## Verificando a aplicação no servidor

```bash
# Ver containers rodando
ssh deploy@195.200.1.191 "docker ps"

# Ver logs de uma aplicação
ssh deploy@195.200.1.191 "docker logs elvisea_portfolio --tail 50"

# Ver config do Nginx
ssh deploy@195.200.1.191 "cat /etc/nginx/sites-available/elvisea_portfolio"
```

---

## Renovação do SSL

O Certbot configura renovação automática via `systemd timer`. Para verificar:

```bash
ssh root@195.200.1.191 "systemctl status certbot.timer"
```

Para renovar manualmente (se necessário):

```bash
ssh root@195.200.1.191 "certbot renew --dry-run"
```

---

## Removendo uma aplicação

```bash
# 1. No servidor — parar e remover o container
ssh deploy@195.200.1.191 "cd ~/apps/<app_name> && docker compose down"

# 2. Remover diretório
ssh deploy@195.200.1.191 "rm -rf ~/apps/<app_name>"

# 3. Remover virtual host Nginx
ssh root@195.200.1.191 "
  rm /etc/nginx/sites-enabled/<app_name>
  rm /etc/nginx/sites-available/<app_name>
  nginx -t && systemctl reload nginx
"

# 4. Revogar certificado SSL (opcional)
ssh root@195.200.1.191 "certbot delete --cert-name <dominio>"
```
