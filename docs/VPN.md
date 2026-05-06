# VPN privada — Headscale + Tailscale

## Visão geral

A VPS Aerobi roda o **Headscale** como control plane VPN self-hosted em `https://headscale.aerobi.com.br`. Os dispositivos (laptop, celular, futuros servidores de aeródromo) usam o **cliente Tailscale oficial** apontando para esse Headscale ao invés do SaaS da Tailscale.

```
[laptop dev] ─┐
[celular]   ─┼──> headscale.aerobi.com.br ──> tailnet (100.64.0.0/10)
[VPS Aerobi]─┘                                       │
[aeródromo] ─┘                                       │
                                                     └─> recursos privados
                                                         (vault.../admin, câmeras, etc.)
```

Hoje a tailnet protege:
- `vault.aerobi.com.br/admin` — só acessível de dentro da tailnet
- (Futuro) câmeras IP em aeródromos
- (Futuro) Postgres direto via tailnet — ver issue #7

O que **continua público** (não muda):
- `vault.aerobi.com.br/` (login do Vaultwarden — extensão Bitwarden e app mobile precisam)
- `api.aerobi.com.br/` (frontend e clientes externos)
- `headscale.aerobi.com.br/` (clientes da tailnet conectam aqui — autenticação por pre-auth key)
- SSH `:22` (CI/CD GitHub Actions)

---

## Tags da tailnet

A política ACL fica em [`roles/headscale/templates/acl.json.j2`](../roles/headscale/templates/acl.json.j2). Tags atuais:

| Tag | Quem usa | Pode acessar |
|---|---|---|
| `tag:vps` | A própria VPS Aerobi (backend) | `tag:airfield` (câmeras dos aeródromos) |
| `tag:airfield` | Servidores locais em aeródromos | (recebe conexões; não inicia) |
| `tag:dev` | Laptops e celulares de admin | `*` (tudo) |

Cada dispositivo nasce com uma tag, atribuída pela pre-auth key usada na conexão.

---

## Adicionar um dispositivo à tailnet

### Passo 1 — Gerar uma pre-auth key

Conecte na VPS e gere uma key com a tag certa pra esse dispositivo:

```bash
ssh deploy@187.127.6.20

# Para um laptop/celular dev/admin:
docker exec headscale headscale preauthkeys create \
  --user 1 --reusable --expiration 90d --tags tag:dev

# Para um servidor de aeródromo (futuro):
docker exec headscale headscale preauthkeys create \
  --user 1 --expiration 90d --tags tag:airfield
```

A key tem o formato `hskey-auth-...`. Guarde-a — você cola no cliente Tailscale.

**`--reusable`**: a mesma key pode autenticar múltiplos dispositivos (use para `tag:dev` se vai cadastrar vários celulares com a mesma key). Sem `--reusable`, a key é one-time-use (recomendado para servidor de aeródromo).

### Passo 2 — Instalar o cliente Tailscale e conectar

#### Linux (laptop dev — Ubuntu/Debian)

```bash
# Instalar
curl -fsSL https://tailscale.com/install.sh | sh

# Conectar ao Headscale
sudo tailscale up \
  --login-server=https://headscale.aerobi.com.br \
  --authkey=hskey-auth-COLE-A-KEY-AQUI \
  --hostname=$(hostname)

# Validar
tailscale status
tailscale ip -4
```

#### macOS

App store oficial **NÃO** funciona com Headscale — usa o Mac App Store binding ao SaaS da Tailscale. Opções:

1. **Tailscale Open Source para macOS** (binário standalone): https://pkgs.tailscale.com/stable/#macos
2. Conecta igual ao Linux:

```bash
sudo tailscale up --login-server=https://headscale.aerobi.com.br --authkey=...
```

#### Android

1. Instalar **Tailscale** da Play Store (app oficial).
2. Abrir o app — primeira tela pede sign in. **Não fazer sign in ainda.**
3. Tocar 3 vezes seguidas no logo do Tailscale (canto superior) para abrir o menu oculto de configuração avançada.
4. Em **Coordination server URL**, colocar `https://headscale.aerobi.com.br`.
5. Voltar e fazer sign in — vai abrir o navegador apontando pro Headscale com instruções.
6. Alternativamente, usar pre-auth key direta: abrir URL no celular:
   ```
   https://headscale.aerobi.com.br/register/<machine-key>
   ```
   (esse fluxo aparece quando o app falha a primeira vez — copia o link, abre no navegador, autoriza com a pre-auth key)

A doc oficial do Headscale tem o passo a passo atualizado: https://headscale.net/stable/usage/connect/android/

#### iOS / iPadOS

1. Instalar **Tailscale** da App Store.
2. Abrir as **Configurações do iOS** (não do app), procurar Tailscale na lista de apps.
3. Em **Alternate Coordination Server URL**, colocar `https://headscale.aerobi.com.br`.
4. Voltar pro app Tailscale, sign in — vai abrir Safari pro Headscale.
5. Quando o navegador pedir, autorizar com a pre-auth key gerada.

Doc oficial: https://headscale.net/stable/usage/connect/apple/

### Passo 3 — Validar

No próprio dispositivo, depois de conectado:

```bash
# Linux/macOS
tailscale status

# Android/iOS
# O app mostra o IP atribuído (formato 100.64.x.y) e a lista de outros nós.
```

Na VPS, conferir que o novo dispositivo apareceu:

```bash
ssh deploy@187.127.6.20
docker exec headscale headscale nodes list
```

---

## Acessar recursos privados

### Vaultwarden /admin

Estando conectado à tailnet, abra no navegador:

```
https://vault.aerobi.com.br/admin
```

Vai pedir o `ADMIN_TOKEN` (mesmo que tinha antes — `rJ0pzY97...` no vault). Se não estiver na tailnet, retorna **403 Forbidden**.

### Postgres direto (em breve — issue #7)

Hoje continua via SSH tunnel (ver `docs/DBEAVER.md`). Depois da issue #7, será possível conectar direto em `100.64.0.1:5432` pela tailnet.

---

## Operação

### Listar nodes na tailnet

```bash
ssh deploy@187.127.6.20
docker exec headscale headscale nodes list
docker exec headscale headscale users list
```

### Revogar um device

```bash
# Pegar o ID do node
docker exec headscale headscale nodes list

# Expirar (marca como revogado, conexões existentes caem)
docker exec headscale headscale nodes expire --identifier <NODE_ID>

# Ou deletar definitivamente
docker exec headscale headscale nodes delete --identifier <NODE_ID>
```

### Renovar pre-auth key (a cada 90 dias)

A key configurada no [`vault.yml`](../inventory/prod/group_vars/all/vault.yml) (`vault_headscale_authkey_vps`) é usada pela própria VPS pra entrar na tailnet. Ela só é consumida quando o `tailscale up` roda na primeira vez — re-runs do playbook pulam (idempotência). Não precisa renovar essa específica a menos que a VPS perca o estado Tailscale.

Para keys de novos dispositivos (`tag:dev`, `tag:airfield`), gere conforme o Passo 1 acima.

### Listar pre-auth keys ativas

```bash
docker exec headscale headscale preauthkeys list --user 1
```

### Revogar uma pre-auth key

```bash
docker exec headscale headscale preauthkeys expire <KEY_PREFIX>
```

### Logs do Headscale

```bash
ssh deploy@187.127.6.20
docker logs -f headscale
```

### Status do daemon Tailscale na VPS

```bash
ssh deploy@187.127.6.20
sudo tailscale status
sudo tailscale ip -4   # 100.64.0.1
```

---

## Troubleshooting

### `tailscale up` falha com "no nodes found"

Significa que a pre-auth key expirou ou já foi consumida (one-time-use). Gerar uma nova.

### `tailscale ping <outro-nó>` falha

- Confirmar via `tailscale status` que ambos os nós estão `idle` ou `active`.
- ACL pode estar bloqueando — checar [`acl.json.j2`](../roles/headscale/templates/acl.json.j2). Tag `tag:airfield → tag:airfield` é deny por design (aeródromos isolados entre si).

### vault.aerobi.com.br/admin retorna 403 mesmo conectado à tailnet

- Confirmar que `tailscale ip -4` retorna IP no range `100.64.0.0/10`.
- O cliente pode estar usando "split tunnel" — confirmar que tráfego pra `vault.aerobi.com.br` passa pela tailnet (não pelo gateway local). Em geral basta o IP de origem da requisição estar no range — DNS resolve normal.

### Headscale não responde

```bash
ssh deploy@187.127.6.20
docker ps | grep headscale          # confirmar que tá rodando
docker logs --tail=50 headscale     # ver erro
docker restart headscale
```

ACL inválido é causa comum (Headscale recusa subir). Se mudou `acl.json.j2`, validar JSON antes de aplicar.

### Recriar a tailnet do zero (último recurso)

Apaga TODOS os dispositivos cadastrados — todos vão precisar re-conectar com pre-auth key nova.

```bash
ssh deploy@187.127.6.20
docker stop headscale
docker volume rm headscale_data
# E zerar o DB:
docker exec postgres psql -U postgres -c "DROP DATABASE headscale; CREATE DATABASE headscale OWNER headscale_user;"
# Re-aplicar
cd ~/projects/aerobi-ansible
ansible-playbook -i inventory/prod playbooks/setup_headscale.yml
```

---

## Referências

- Research que motivou Headscale (vs Tailscale SaaS): [`docs/research/private-network.md`](research/private-network.md)
- Issue de implementação: https://github.com/atzaero/aerobi-ansible/issues/5
- Headscale upstream: https://github.com/juanfont/headscale
- Headscale docs: https://headscale.net/stable/
