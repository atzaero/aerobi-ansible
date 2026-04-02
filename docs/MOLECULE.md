# Testes com Molecule

## O que é o Molecule

Molecule é a ferramenta oficial de testes para projetos Ansible. Ele:

1. Sobe um container Docker com Ubuntu 24.04
2. Roda o playbook dentro do container (como se fosse uma VPS real)
3. Executa verificações para confirmar que tudo foi configurado corretamente
4. Destrói o container ao final

Isso permite testar sem precisar de uma VPS real.

---

## Instalação

```bash
# Entrar na pasta do projeto
cd ~/projects/ansible-vps

# Criar ambiente virtual Python (recomendado)
python3 -m venv .venv

# Ativar o ambiente virtual
source .venv/bin/activate

# Instalar Molecule e dependências
pip install ansible molecule molecule-plugins[docker]

# Verificar instalação
molecule --version
```

**Nota:** o ambiente virtual (`.venv`) é ignorado pelo Git via `.gitignore`. Você precisará recriar em cada máquina nova.

---

## Comandos principais

```bash
# Rodar o ciclo completo de testes (recomendado)
molecule test

# Apenas subir o container (sem rodar playbook)
molecule create

# Rodar o playbook no container existente
molecule converge

# Rodar apenas as verificações
molecule verify

# Acessar o container via SSH para debugar
molecule login

# Destruir o container
molecule destroy
```

---

## Ciclo completo do `molecule test`

Quando você roda `molecule test`, ele executa em ordem:

```
1. dependency   → baixa dependências (galaxy)
2. syntax       → valida sintaxe YAML dos playbooks
3. create       → sobe o container Docker
4. prepare      → (opcional) prepara o container
5. converge     → roda o playbook (converge.yml)
6. idempotency  → roda o playbook de novo (deve ter 0 mudanças)
7. verify       → roda as verificações (verify.yml)
8. destroy      → destrói o container
```

O teste de **idempotência** é importante: um playbook Ansible bem escrito não deve fazer mudanças quando rodado duas vezes. Se algo muda na segunda execução, há um problema.

---

## Estrutura dos arquivos

```
molecule/
└── default/
    ├── molecule.yml    # configuração do ambiente de teste
    ├── converge.yml    # playbook executado no container
    └── verify.yml      # testes de verificação
```

### molecule.yml

Define qual imagem Docker usar, variáveis do ambiente de teste e configurações gerais.

### converge.yml

É o playbook que roda dentro do container. Atualmente executa todas as roles do `setup_vps.yml`.

### verify.yml

Verifica se as configurações foram aplicadas corretamente. Cada task é uma asserção — se falhar, o teste falha.

---

## Verificações implementadas

O `verify.yml` confirma que:

- Usuário `deploy` foi criado
- Diretórios `apps/`, `databases/`, `scripts/`, `backups/` existem
- Nginx está rodando
- Fail2Ban está rodando
- Docker está rodando
- UFW está ativo
- SSH está com `PermitRootLogin no`
- SSH está com `PasswordAuthentication no`

---

## Fluxo recomendado antes de aplicar em prod

```bash
# 1. Ativar ambiente virtual
source .venv/bin/activate

# 2. Testar localmente
molecule test

# 3. Se passou, aplicar em dev
ansible-playbook -i inventory/dev playbooks/setup_vps.yml

# 4. Validar dev manualmente
ssh deploy@IP_DEV

# 5. Aplicar em prod
ansible-playbook -i inventory/prod playbooks/setup_vps.yml
```
