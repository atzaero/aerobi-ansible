# Como usar este projeto

## Visão geral

O Ansible conecta via SSH na sua VPS e executa as configurações automaticamente. Você não precisa entrar no servidor manualmente.

```
Sua máquina  --SSH-->  VPS (Ubuntu 24.04)
  (Ansible)
```

---

## Passo 1 — Instalar dependências

```bash
# Entrar na pasta do projeto
cd ~/projects/ansible-vps

# Criar ambiente virtual Python
python3 -m venv .venv
source .venv/bin/activate

# Instalar Ansible e Molecule
pip install ansible molecule molecule-plugins[docker]
```

---

## Passo 2 — Configurar o inventário

Edite o arquivo do ambiente desejado com o IP da sua VPS:

```bash
# Para dev
vim inventory/dev/hosts.yml

# Para prod
vim inventory/prod/hosts.yml
```

```yaml
all:
  hosts:
    vps-prod:
      ansible_host: 195.200.1.191   # IP da VPS
      ansible_user: root
      ansible_ssh_private_key_file: ~/.ssh/id_ed25519
```

---

## Passo 3 — Configurar variáveis

Edite as variáveis do ambiente:

```bash
vim inventory/prod/group_vars/all.yml
```

O campo mais importante é a chave SSH pública:

```bash
# Obter sua chave pública
cat ~/.ssh/id_ed25519.pub
```

Cole o resultado em `deploy_ssh_public_key`.

---

## Passo 4 — Testar com Molecule (recomendado)

Antes de aplicar em qualquer VPS, teste localmente:

```bash
molecule test
```

Se todos os testes passarem, pode prosseguir com segurança.

---

## Passo 5 — Testar conexão com a VPS

```bash
ansible -i inventory/prod all -m ping
```

Resposta esperada:
```
vps-prod | SUCCESS => { "ping": "pong" }
```

---

## Passo 6 — Executar o playbook

```bash
# Configuração completa em dev
ansible-playbook -i inventory/dev playbooks/setup_vps.yml

# Configuração completa em prod
ansible-playbook -i inventory/prod playbooks/setup_vps.yml

# Apenas instalar Docker
ansible-playbook -i inventory/prod playbooks/setup_docker.yml
```

---

## Executar apenas partes específicas (tags)

```bash
# Apenas segurança
ansible-playbook -i inventory/prod playbooks/setup_vps.yml --tags security

# Apenas Docker e Nginx
ansible-playbook -i inventory/prod playbooks/setup_vps.yml --tags docker,nginx

# Dry-run (ver o que vai acontecer sem executar)
ansible-playbook -i inventory/prod playbooks/setup_vps.yml --check
```

Tags disponíveis: `common`, `user`, `ssh`, `security`, `firewall`, `fail2ban`, `nginx`, `docker`

---

## Após a execução

Reconecte usando o usuário `deploy`:

```bash
ssh deploy@IP_DA_VPS
```

**Importante:** o Docker só funciona sem `sudo` após reconectar a sessão SSH.

---

## Modo verbose (para debugar)

```bash
ansible-playbook -i inventory/prod playbooks/setup_vps.yml -vv
```
