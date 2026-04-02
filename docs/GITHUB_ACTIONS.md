# Deploy via GitHub Actions

## Como funciona

O GitHub Actions faz SSH no VPS como usuário `deploy` e executa os
comandos de deploy remotamente. A chave SSH usada pelo CI/CD é separada
da chave do desenvolvedor — se precisar revogar o acesso do CI/CD, basta
remover a entrada do Ansible sem afetar o acesso manual.

```
GitHub Actions (CI)
    └── SSH (chave dedicada cicd_key)
            └── deploy@195.200.1.191
                    └── cd ~/apps/minha_app
                        docker compose pull
                        docker compose up -d
```

---

## Configuração inicial (feita uma vez)

### 1. A chave CI/CD já está configurada no VPS

A chave pública do CI/CD foi adicionada ao Ansible e aplicada no VPS.
Para confirmar:

```bash
ssh deploy@195.200.1.191 "cat ~/.ssh/authorized_keys"
# Deve listar as duas chaves: desenvolvedor e GitHub Actions
```

### 2. Adicionar a chave privada no GitHub

A chave privada gerada (`cicd_deploy_key`) deve ser armazenada como
Secret em **cada repositório** que vai fazer deploy neste VPS.

**Caminho no GitHub:**
```
Repositório → Settings → Secrets and variables → Actions → New repository secret
```

| Nome do Secret | Valor |
|---|---|
| `SSH_HOST` | `195.200.1.191` |
| `SSH_USER` | `deploy` |
| `SSH_PRIVATE_KEY` | conteúdo do arquivo `cicd_deploy_key` (chave privada) |
| `SSH_PORT` | `22` |

> A chave privada está em `/tmp/cicd_deploy_key` na máquina local.
> Exibir com: `cat /tmp/cicd_deploy_key`
> **Guarde em local seguro — não versione a chave privada.**

---

## Exemplo de workflow

Crie o arquivo `.github/workflows/deploy.yml` no repositório da aplicação:

```yaml
name: Deploy

on:
  push:
    branches: [main]   # dispara a cada push na branch main

jobs:
  deploy:
    runs-on: ubuntu-latest

    steps:
      - name: Deploy via SSH
        uses: appleboy/ssh-action@v1
        with:
          host: ${{ secrets.SSH_HOST }}
          username: ${{ secrets.SSH_USER }}
          key: ${{ secrets.SSH_PRIVATE_KEY }}
          port: ${{ secrets.SSH_PORT }}
          script: |
            set -e   # para na primeira falha

            cd ~/apps/viki_assistant

            # Puxa a imagem mais recente (se usar registry)
            docker compose pull

            # Recria containers com a nova imagem
            docker compose up -d --remove-orphans

            # Remove imagens antigas para liberar espaço
            docker image prune -f

            echo "Deploy concluído com sucesso!"
```

### Variações comuns

**Com build local e push para registry:**
```yaml
jobs:
  build-and-push:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Login no Docker Hub
        uses: docker/login-action@v3
        with:
          username: ${{ secrets.DOCKERHUB_USER }}
          password: ${{ secrets.DOCKERHUB_TOKEN }}

      - name: Build e push da imagem
        uses: docker/build-push-action@v5
        with:
          push: true
          tags: usuario/viki_assistant:latest

  deploy:
    needs: build-and-push   # só roda após o build
    runs-on: ubuntu-latest
    steps:
      - name: Deploy via SSH
        uses: appleboy/ssh-action@v1
        with:
          host: ${{ secrets.SSH_HOST }}
          username: ${{ secrets.SSH_USER }}
          key: ${{ secrets.SSH_PRIVATE_KEY }}
          port: ${{ secrets.SSH_PORT }}
          script: |
            cd ~/apps/viki_assistant
            docker compose pull
            docker compose up -d --remove-orphans
            docker image prune -f
```

**Deploy somente se os testes passarem:**
```yaml
on:
  push:
    branches: [main]

jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Rodar testes
        run: npm test   # ou pytest, go test, etc.

  deploy:
    needs: test   # deploy só acontece se test passar
    runs-on: ubuntu-latest
    steps:
      - name: Deploy via SSH
        uses: appleboy/ssh-action@v1
        ...
```

---

## Estrutura de diretórios esperada no VPS

O usuário `deploy` tem o diretório `~/apps` para as aplicações:

```
/home/deploy/
└── apps/
    ├── viki_assistant/
    │   ├── docker-compose.yml
    │   └── .env
    └── barber_shop/
        ├── docker-compose.yml
        └── .env
```

Para criar a estrutura de uma nova app:
```bash
ssh deploy@195.200.1.191
mkdir -p ~/apps/minha_app
# Copiar docker-compose.yml e .env
```

---

## Gerenciar chaves SSH via Ansible

As chaves autorizadas são controladas em:
`inventory/prod/group_vars/all/all.yml` → variável `deploy_ssh_authorized_keys`

**Adicionar nova chave (ex: novo desenvolvedor):**
```yaml
deploy_ssh_authorized_keys:
  - comment: "Desenvolvedor — elvisea"
    key: "ssh-ed25519 AAAA..."
  - comment: "GitHub Actions — CI/CD deploy"
    key: "ssh-ed25519 AAAA..."
  # Nova entrada:
  - comment: "Desenvolvedor — nome do novo dev"
    key: "ssh-ed25519 AAAA... (chave pública do novo dev)"
```

Depois aplicar:
```bash
ansible-playbook playbooks/setup_vps.yml --tags user
```

**Revogar uma chave:**
Remover a entrada da lista e rodar o playbook.
> Atenção: o módulo `authorized_key` do Ansible apenas adiciona chaves,
> não remove as que não estão na lista. Para remover, edite manualmente
> `~/.ssh/authorized_keys` no VPS ou adicione `exclusive: yes` na task
> (o que sobrescreve o arquivo inteiro com apenas as chaves da lista).
