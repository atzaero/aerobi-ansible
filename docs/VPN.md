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

**Importante:** a **tag não é só rótulo organizacional** — é a **identidade ACL** do device. Quando um device entra na tailnet, ele herda a tag da pre-auth key usada e fica permanentemente marcado com ela. As regras ACL acima decidem o tráfego permitido a partir dessa tag.

Por isso, escolher a tag certa na hora de gerar a key é crítico: um servidor de aeródromo provisionado com `tag:dev` por engano teria acesso admin a toda a tailnet.

---

## Métodos de autenticação

Existem três formas de adicionar um device à tailnet. A escolha depende do contexto (quem é o cliente, qual o nível de risco, automatizado ou manual).

| Método | Quando usar | Distribuição da credencial | Esforço |
|---|---|---|---|
| **A. Pre-auth key reusable** | Time pequeno (admins atuais), múltiplos devices da mesma pessoa, fluxo conveniente | Compartilhar a key uma vez, válida até expirar | Baixo |
| **B. Pre-auth key single-use** | Servidores de aeródromo, provisionamento automatizado, segurança maior | Uma key por device, consumida na primeira conexão | Médio |
| **C. Registro manual (machine key)** | Cliente externo sem credencial pré-distribuída, cenários sensíveis | Admin registra a machine key do device pelo CLI | Alto, mas mais auditável |

Em todos os métodos, a tag (`tag:dev`, `tag:airfield`, etc.) é atribuída — seja ao gerar a key (A, B) ou ao registrar a machine key (C).

### Método A — Pre-auth key reusable

**Quando usar:** time pequeno cadastrando vários devices (laptop + celular + tablet do mesmo admin). Reduz fricção operacional.

**Como funciona:** você gera uma key uma vez e ela autentica vários devices até expirar. É a forma usada hoje pro `tag:dev`.

**Como gerar:**

```bash
ssh deploy@187.127.6.20
docker exec headscale headscale preauthkeys create \
  --user 1 --reusable --expiration 90d --tags tag:dev
# Output: hskey-auth-...
```

**Como o cliente usa:** cola a string `hskey-auth-...` no campo "auth key" do cliente Tailscale (Linux/macOS via `--authkey=...`, Android/iOS via menu **Use an auth key**). Ver [Como conectar](#passo-1--instalar-o-cliente-tailscale-e-conectar) abaixo.

**Riscos:**
- Se a key vazar (chat, e-mail), qualquer um pode entrar na tailnet com a tag até expirar.
- Sem auditoria de "qual key autenticou cada device" — todos compartilham a mesma origem.

**Boas práticas:**
- Rodar em chats efêmeros (Signal disappearing messages, vault interno) ou via Vaultwarden Send.
- Rotacionar (gerar nova + revogar velha) se suspeitar de vazamento ou alguém sair do time.
- Re-gerar a cada 90 dias quando expirar.

### Método B — Pre-auth key single-use

**Quando usar:** servidor de aeródromo (provisionado via Ansible que consome a key automaticamente), cenários onde cada device deve ter sua própria credencial.

**Como funciona:** sem `--reusable`, a key é descartada na primeira conexão bem-sucedida.

**Como gerar:**

```bash
ssh deploy@187.127.6.20
docker exec headscale headscale preauthkeys create \
  --user 1 --expiration 90d --tags tag:airfield
# Output: hskey-auth-... (válida por 90 dias OU até ser consumida — o que vier primeiro)
```

**Como o cliente usa:** mesma forma do Método A — cola a key e conecta. Diferença é que a key vira inválida depois.

**Boas práticas:**
- Gerar a key e consumir no mesmo provisionamento (Ansible role `tailscale_client` no servidor de aeródromo).
- Não armazenar a key depois de usada — não tem mais valor.

### Método C — Registro manual (sem pre-auth key)

**Quando usar:** quando você não quer (ou não pode) distribuir uma credencial pré-autorizada antes do device tentar conectar. Útil pra clientes externos eventuais ou auditoria.

**Como funciona:** o cliente tenta logar no Headscale sem auth key. O Headscale gera uma **machine key** e mostra uma tela "Machine Registration" com um comando que o admin precisa executar pra autorizar o device.

**Fluxo do lado do cliente:**

1. Configurar o cliente Tailscale apontando pra `https://headscale.aerobi.com.br` (ver [Conectando](#passo-1--instalar-o-cliente-tailscale-e-conectar) abaixo) — sem fornecer auth key.
2. O app abre uma URL/tela do Headscale com texto tipo:
   ```
   Machine Registration
   Run the command below in the headscale server:
   headscale nodes register --user <USER> --key mkey:abc123...
   ```
3. Cliente envia esse `mkey:...` para o admin (chat, e-mail).

**Fluxo do lado do admin (na VPS):**

```bash
ssh deploy@187.127.6.20

# Registrar atribuindo a tag certa
docker exec headscale headscale nodes register \
  --user 1 \
  --key mkey:abc123... \
  --tags tag:dev
```

**Vantagens:**
- Nenhuma credencial pré-distribuída — admin valida cada cadastro caso a caso.
- Auditoria fica clara: cada device tem uma machine key única e foi registrado por um admin específico (nos logs do Headscale).

**Desvantagens:**
- Admin precisa ser interativo: cliente espera o registro acontecer.
- Mais fricção pra cadastros em massa.

### Resumo de decisão

```
Vai cadastrar 1 ou 2 devices manualmente, com você por perto?
  → Método A (reusable, conveniente)

É um servidor de aeródromo provisionado por Ansible?
  → Método B (single-use, integrado ao provisioning)

Cliente externo eventual / auditoria importa?
  → Método C (registro manual)
```

---

## Adicionar um dispositivo à tailnet

### Passo 1 — Obter credencial

Escolha o método em [Métodos de autenticação](#métodos-de-autenticação) acima e gere/prepare a credencial:

- Método A ou B: gere a pre-auth key e copie a string `hskey-auth-...`.
- Método C: configure o cliente primeiro (passo 2 abaixo), pegue a `mkey:...` que aparecer e registre.

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

App da Mac App Store está atrelado ao SaaS da Tailscale e não permite trocar de servidor. Duas opções:

**Via CLI** (mais simples):

```bash
# Instalar (Homebrew)
brew install tailscale

# Conectar
sudo tailscale login --login-server=https://headscale.aerobi.com.br
# (abre o navegador; cole a pre-auth key na tela do Headscale)

# Ou direto com a key:
sudo tailscale up --login-server=https://headscale.aerobi.com.br --authkey=hskey-auth-...
```

**Via GUI** (binário oficial standalone):

1. Baixar de https://pkgs.tailscale.com/stable/#macos (NÃO da Mac App Store)
2. Instalar e abrir
3. Segurar **⌥ Option** e clicar no ícone do Tailscale no menu bar → menu **Debug**
4. **Add Account...** dentro de **Custom Login Server**
5. URL: `https://headscale.aerobi.com.br`
6. Seguir o login no navegador (cola a pre-auth key)

#### Android

Interface do app Tailscale Android (versão atual, doc oficial Headscale):

1. Instalar **Tailscale** da Play Store.
2. Abrir o app → ícone de **configurações** no canto superior direito.
3. Tocar em **Accounts**.
4. Ícone de **três pontos** (⋮) → **Use an alternate server**.
5. URL: `https://headscale.aerobi.com.br` → confirmar.
6. Se a tela de login web aparecer, fechar.
7. Voltar para **Accounts**.
8. Ícone de **três pontos** (⋮) novamente → **Use an auth key**.
9. Colar a pre-auth key (formato `hskey-auth-...`) → confirmar.
10. Tocar **Log in** na tela principal se necessário.

Pronto — o app passa a mostrar o IP da tailnet (`100.64.x.y`) e a lista de outros nós.

Doc oficial atualizada: https://headscale.net/stable/usage/connect/android/

#### iOS / iPadOS

Interface do app Tailscale iOS (versão atual, doc oficial Headscale):

1. Instalar **Tailscale** da App Store.
2. Abrir o app → ícone de **conta** no canto superior direito.
3. Tocar em **Log in…**.
4. Menu **⋯** (canto superior direito) → **Use custom coordination server**.
5. URL: `https://headscale.aerobi.com.br` → confirmar.
6. Seguir o login (Safari abre apontando pro Headscale; cole a pre-auth key na tela).

Pronto.

Doc oficial atualizada: https://headscale.net/stable/usage/connect/apple/

#### Sem pre-auth key (Método C — registro manual)

Em qualquer plataforma acima, se você **pular a etapa de fornecer auth key** (não passar `--authkey=...` no Linux/macOS, ou não tocar **Use an auth key** no Android/iOS), o cliente Tailscale vai pedir login web e te direcionar pra uma tela do Headscale tipo:

```
Machine Registration
Run the command below in the headscale server to add this machine to your network:
headscale nodes register --user 1 --key mkey:c90c7456a90428fb2a9c6c05e8e5b2a188...
```

Copie a `mkey:...` exibida e envie ao admin. O admin, na VPS, executa:

```bash
ssh deploy@187.127.6.20
docker exec headscale headscale nodes register \
  --user 1 \
  --key mkey:c90c7456a90428fb2a9c6c05e8e5b2a188... \
  --tags tag:dev
```

Em poucos segundos o cliente conecta automaticamente — a tela de "Machine Registration" some sozinha.

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

## Comandos do dia a dia — cliente Tailscale (sua máquina)

Os comandos abaixo são para o cliente Tailscale rodando no laptop/desktop (Linux/macOS). No Android/iOS, as ações equivalentes ficam no app — o que está aqui pressupõe terminal.

### Conexão e desconexão

```bash
# Conectar (primeira vez ou depois de logout)
sudo tailscale up \
  --login-server=https://headscale.aerobi.com.br \
  --authkey=hskey-auth-... \
  --hostname=$(hostname)

# Desconectar — preserva configuração e credenciais; basta `tailscale up`
# (sem flags) para reconectar depois.
sudo tailscale down

# Reconectar após `down` (sem precisar de auth key de novo)
sudo tailscale up

# Logout total — apaga credenciais. Próxima conexão precisa de nova auth key.
sudo tailscale logout
```

### Status e diagnóstico

```bash
# Ver nós da tailnet, status de conexão de cada um e seu próprio IP
tailscale status

# Apenas seu IP IPv4 / IPv6 na tailnet
tailscale ip -4
tailscale ip -6

# JSON estruturado (útil pra scripts)
tailscale status --json

# Testa conexão peer-to-peer com outro nó (latência + caminho usado: direto vs DERP)
tailscale ping vps-prod
tailscale ping 100.64.0.1

# Diagnóstico de NAT, DERP relays e conectividade UDP
tailscale netcheck

# Quem é o dono de um IP da tailnet?
tailscale whois 100.64.0.1
```

### Ajustar settings sem desconectar

```bash
# Habilitar DNS push do Headscale (extra_records) — necessário pra
# vault.aerobi.com.br resolver via tailnet
sudo tailscale set --accept-dns=true

# Aceitar rotas anunciadas por outros nós (ex: subnet de câmeras
# anunciada por servidor de aeródromo)
sudo tailscale set --accept-routes=true

# Mudar hostname do nó (sem reconectar)
sudo tailscale set --hostname=novo-nome
```

### Daemon e systemd

```bash
# Status do daemon
systemctl status tailscaled

# Logs em tempo real
journalctl -u tailscaled -f

# Reiniciar (geralmente desnecessário)
sudo systemctl restart tailscaled
```

### Versão

```bash
tailscale version
```

---

## Comandos do dia a dia — servidor Headscale (VPS)

Conectar primeiro:

```bash
ssh deploy@187.127.6.20
```

Todos os comandos abaixo rodam **dentro** do container `headscale` via `docker exec`.

### Listar usuários e nodes

```bash
# Usuários da tailnet (hoje só "aerobi" com id=1)
docker exec headscale headscale users list

# Todos os nodes (sua VPS, laptops, celulares, etc.)
docker exec headscale headscale nodes list

# Mesmo, em JSON (útil pra scripts)
docker exec headscale headscale nodes list -o json
```

### Gerenciar nodes

```bash
# Renomear (resolve placeholder tipo "invalid-b2hd95oi" do Android)
docker exec headscale headscale nodes rename --identifier 3 android-elvis

# Expirar (marca como revogado; conexões existentes caem na próxima validação)
docker exec headscale headscale nodes expire --identifier <ID>

# Deletar definitivamente (não recupera; o IP fica livre pra reuso)
docker exec headscale headscale nodes delete --identifier <ID>

# Mudar tags de um node já cadastrado
docker exec headscale headscale nodes tag --identifier <ID> --tags tag:dev

# Registrar manualmente uma machine key (Método C de autenticação)
docker exec headscale headscale nodes register \
  --user 1 --key mkey:abc123... --tags tag:dev
```

### Gerenciar pre-auth keys

```bash
# Criar key reusable para devices admin
docker exec headscale headscale preauthkeys create \
  --user 1 --reusable --expiration 90d --tags tag:dev

# Criar key one-time-use para servidor de aeródromo
docker exec headscale headscale preauthkeys create \
  --user 1 --expiration 90d --tags tag:airfield

# Listar keys (ativas e expiradas)
docker exec headscale headscale preauthkeys list --user 1

# Expirar uma key (revoga)
docker exec headscale headscale preauthkeys expire <KEY>
```

### ACL (políticas de acesso)

```bash
# Ver a ACL atual aplicada
docker exec headscale headscale policy get

# Aplicar uma ACL nova (já vem montada via Ansible em /etc/headscale/acl.json,
# mas se quiser reaplicar manualmente após mexer no template):
docker exec headscale headscale policy set -f /etc/headscale/acl.json

# Validar o config.yaml inteiro sem reiniciar
docker exec headscale headscale configtest
```

### Saúde, versão, logs

```bash
# Health check (exatamente o mesmo que o Docker healthcheck usa)
docker exec headscale headscale health

# Versão
docker exec headscale headscale version

# Logs (toda a saída do daemon)
docker logs headscale

# Logs em tempo real (Ctrl+C para sair)
docker logs -f headscale

# Últimas N linhas
docker logs --tail=50 headscale

# Restart do container (não derruba a tailnet — clientes reconectam sozinhos)
docker restart headscale
```

### Daemon Tailscale na própria VPS

A VPS também é um cliente Tailscale (com IP `100.64.0.1`). Os mesmos comandos de cliente acima funcionam aqui, prefixando `sudo`:

```bash
sudo tailscale status
sudo tailscale ip -4   # 100.64.0.1
```

### Renovar a pre-auth key da VPS (a cada 90 dias)

A key configurada em [`vault.yml`](../inventory/prod/group_vars/all/vault.yml) (`vault_headscale_authkey_vps`) é usada apenas no primeiro `tailscale up` da VPS. Re-runs do playbook pulam (idempotência), então a renovação só importa se a VPS perder o estado Tailscale (volume `/var/lib/tailscale` deletado, reinstalação, etc).

Pra novas keys de admin/aeródromo, ver [Métodos de autenticação](#métodos-de-autenticação) acima.

---

## Perguntas frequentes

### Por que o app mostra todos os dispositivos da tailnet?

Tailscale é uma **mesh VPN**: nós conversam direto entre si (peer-to-peer) sem passar pela VPS como gateway. Pra isso funcionar, cada nó precisa saber quais peers existem, qual a chave pública WireGuard de cada e qual o IP da tailnet correspondente. O Headscale (control plane) distribui essa lista para todos os nós conectados.

**Visibilidade não é acesso.** A lista mostra quem existe na rede, mas quem pode conversar com quem é decidido pela ACL ([`acl.json.j2`](../roles/headscale/templates/acl.json.j2)). Hoje:

- `tag:dev` (laptop/celular admin) → conversa com tudo
- `tag:vps` (a VPS) → conversa só com `tag:airfield`
- `tag:airfield` (aeródromos, futuro) → recebe da VPS, não conversa entre si nem com `tag:vps`

Se um aeródromo for cadastrado amanhã, ele aparece na lista de todos os clientes — mas tentar `tailscale ping airfield-1` de outro aeródromo vai falhar porque a ACL nega.

### Posso esconder os outros dispositivos na lista?

Não trivialmente — a lista é parte do funcionamento do protocolo. Use ACLs para controlar **acesso**, não visibilidade.

### Tailscale criptografa o tráfego?

Sim. Cada par de nós estabelece um túnel WireGuard com chaves derivadas no momento da conexão. Nem o Headscale (control plane) consegue ler o tráfego — só coordena handshakes. Mesmo se a VPS for comprometida, o tráfego histórico entre nós permanece confidencial (forward secrecy).

### Tudo passa pela VPS?

**Não.** Por padrão é peer-to-peer direto entre os nós. Quando o NAT impede conexão direta (carrier-grade NAT em rede móvel, p.ex.), o tráfego cai num **DERP relay** público da Tailscale como fallback — mas continua criptografado fim-a-fim, o relay só vê pacotes opacos. Veja `tailscale ping <peer>` para descobrir qual caminho está em uso (`direct` vs `via DERP <região>`).

### Estando conectado à tailnet, minha navegação na internet passa pela VPS?

**Não, por padrão.** O Tailscale opera em modo **split tunnel**:

| Tráfego | Caminho |
|---|---|
| google.com, YouTube, WhatsApp, banco, navegação geral | Sai pela rede normal (4G/Wi-Fi do ISP); a VPS não vê |
| IPs do range `100.64.0.0/10` | Tailnet (P2P direto entre peers) |
| Domínios em `extra_records` do Headscale (hoje `vault.aerobi.com.br`) | Tailnet (resolvem pra IP `100.64.x.y`) |

Seu ISP local continua enxergando seu tráfego de internet como antes. A VPS Aerobi não participa dele.

**Exceção — Exit Node.** No app Tailscale aparece um campo "Exit Node" (default: `None`). Esse recurso permite rotear **todo** o tráfego de internet por outro nó da tailnet (útil em Wi-Fi público suspeito, p.ex.). **A VPS Aerobi (`vps-prod`) está configurada como exit node disponível** — basta selecionar no app pra ativar. Ver [Como usar a VPS como exit node](#como-usar-a-vps-como-exit-node) abaixo.

### Os outros dispositivos da tailnet veem minha navegação?

**Não.** Cada par de nós tem seu próprio túnel WireGuard criptografado. Outros peers veem só:

- Seu hostname (`android-elvis`) e IP da tailnet (`100.64.0.3`)
- Status online/offline
- Sistema operacional reportado pelo cliente
- Última vez visto (timestamp)
- Seu IP público durante o handshake inicial (usado pra estabelecer conexão direta; não fica armazenado depois)

**Não veem:** sites visitados, conteúdo de tráfego, apps em uso, localização GPS, dados pessoais. Mesmo o Headscale (control plane) só vê metadados de coordenação — nunca o conteúdo do tráfego entre peers.

### Quais preocupações de privacidade são reais aqui?

- **Pre-auth keys são credenciais.** Quem tiver a string `hskey-auth-...` reusable pode entrar na tailnet como `tag:dev` (acesso a tudo) até a key expirar. Se suspeitar de vazamento: `docker exec headscale headscale preauthkeys expire <key>` revoga, e gere uma nova.
- **Visibilidade dentro da `tag:dev`.** Hoje todos os admins estão no mesmo user (`aerobi`) e veem online/offline uns dos outros. Pra isolar, criar users separados ou ACLs mais finas — não é prioridade no setup atual.
- **Hostname revela informação.** Padrão `android-elvis` / `iphone-maria` revela quem é. Se preferir anonimizar, renomear via `headscale nodes rename` para algo neutro tipo `dev-3`.

O que **não** é preocupação:

- Navegação web do dia a dia continua privada como antes da VPN.
- A VPS não "espiona" tráfego entre peers — o WireGuard usa forward secrecy.
- Mesmo aparecendo na lista de peers, outros nós só conseguem te conectar se a ACL permitir.

---

## Como usar a VPS como exit node

A VPS Aerobi está configurada para anunciar-se como exit node (`tailscale_advertise_exit_node: true` em [`inventory/prod/host_vars/vps-prod.yml`](../inventory/prod/host_vars/vps-prod.yml)) e a rota `0.0.0.0/0` já está aprovada no Headscale. O recurso fica **disponível, mas inativo por padrão** — cada cliente escolhe se quer usar ou não.

### Ativar no app mobile

1. Abrir o app Tailscale no celular.
2. Tocar em **Choose exit node** (no card "EXIT NODE" da tela principal).
3. Selecionar **vps-prod**.

Pronto — todo o tráfego web do celular passa a sair pela VPS. Pra desativar, voltar em **Choose exit node** e selecionar **None**.

### Ativar no Linux/macOS (CLI)

```bash
# Listar exit nodes disponíveis
tailscale exit-node list

# Ativar
sudo tailscale set --exit-node=vps-prod

# Desativar (voltar ao modo split tunnel)
sudo tailscale set --exit-node=
```

### Quando vale a pena usar

- **Wi-Fi público / hotel / aeroporto / café**: tráfego sai criptografado pela tailnet até a VPS, evita sniffing local.
- **Geo-bloqueio**: sites que checam IP brasileiro (a VPS está no Brasil — Hostinger).
- **Contornar rede corporativa restritiva**: se o Wi-Fi local bloqueia certos sites, a VPS atua como saída.

### Trade-offs (importante)

- **Latência aumenta**: todo o tráfego dá uma volta pela VPS antes de sair pra internet. Streaming/jogos podem sentir.
- **Banda da VPS é compartilhada**: se vários peers usarem como exit node ao mesmo tempo, divide a banda da Hostinger.
- **Quem opera a VPS vê metadados do tráfego**: a Hostinger (provedor) e você (operador) conseguem ver DNS queries e IPs de destino. **Conteúdo HTTPS continua criptografado fim-a-fim** com os sites visitados — ninguém vê senhas/dados que você digitou em sites HTTPS.
- **IP de origem muda**: requests web saem com o IP da VPS (`187.127.6.20`), não com seu IP residencial/móvel. Alguns sites (banco, captcha) podem questionar login de IP novo.

Por isso é **opt-in** — só ative quando o cenário pedir.

### Como foi configurado

Caso precise mexer no futuro:

1. **Anunciar como exit node** (já feito): em `inventory/prod/host_vars/vps-prod.yml`:
   ```yaml
   tailscale_advertise_exit_node: true
   ```
   A role `tailscale_client` aplica via `tailscale set --advertise-exit-node=true`.

2. **Aprovar a rota no Headscale** (passo manual, único): a rota fica `Available` mas precisa de aprovação explícita do admin.
   ```bash
   ssh deploy@187.127.6.20
   docker exec headscale headscale nodes list-routes
   docker exec headscale headscale nodes approve-routes \
     --identifier 1 --routes '0.0.0.0/0,::/0'
   ```
   Após aprovado, fica permanente.

3. **Para reverter** (caso queira desabilitar):
   ```bash
   # Remover aprovação da rota
   docker exec headscale headscale nodes approve-routes --identifier 1 --routes ''
   # E em host_vars/vps-prod.yml: tailscale_advertise_exit_node: false
   # Re-aplicar: ansible-playbook ... --tags tailscale
   ```

---

## "Run as exit node" e "Allow LAN access" no app mobile — para que servem?

Telas que aparecem dentro de **Choose exit node** no app Tailscale Android/iOS:

### Run as exit node

Oferece o **próprio celular** como saída de internet para outros peers da tailnet — o oposto de usar a VPS como exit node. **Não ative.** Os trade-offs do app são bem realistas:

- Gasta bateria significativamente (rádio em uso constante).
- Dados móveis de outros peers passam pela sua linha (custo, plano).
- Expõe sua conexão pessoal a uso por outros nós.

Faz sentido apenas em cenários muito específicos (ex: quer compartilhar internet do celular com um servidor remoto para algum teste). Não é o caso aqui.

### Allow LAN access

Controla se, **estando conectado à tailnet**, o cliente Tailscale ainda consegue acessar dispositivos da sua rede local (Chromecast, impressora Wi-Fi de casa, NAS, roteador). Default: **off**.

- Off (recomendado): mais seguro, evita que peers da tailnet acidentalmente acessem sua rede local através do seu device.
- On: útil se você precisa imprimir/usar dispositivos locais enquanto está conectado à tailnet.

Para o nosso uso típico (acessar `/admin` da VPS, futuros aeródromos), **deixe Off**.

---

## Troubleshooting

### `tailscale up` falha com "no nodes found"

Significa que a pre-auth key expirou ou já foi consumida (one-time-use). Gerar uma nova.

### `tailscale ping <outro-nó>` falha

- Confirmar via `tailscale status` que ambos os nós estão `idle` ou `active`.
- ACL pode estar bloqueando — checar [`acl.json.j2`](../roles/headscale/templates/acl.json.j2). Tag `tag:airfield → tag:airfield` é deny por design (aeródromos isolados entre si).

### Subdomínio tailnet-only retorna 403 mesmo conectado à tailnet

Causa #1 (mais comum): **subdomínio não está em `headscale_extra_dns_records`**. O cliente resolve o domínio para o IP público (`187.127.6.20`) via DNS público, e o tráfego sai pela internet em vez da `tailscale0`. O nginx vê o IP público em `$remote_addr` → bloqueia.

Diagnóstico:
```bash
# Esperado em cliente com tailscale up + --accept-dns=true:
dig +short <sub>.aerobi.com.br @100.100.100.100    # deve retornar 100.64.0.1

# Se retornar 187.127.6.20 → falta entrada em extra_records.
# Editar roles/headscale/defaults/main.yml e reaplicar setup_headscale.yml.
```

Causa #2: cliente com `--accept-dns=false`. Reativar:
```bash
sudo tailscale set --accept-dns=true
```

Causa #3: `tailscale ip -4` não retorna IP no range `100.64.0.0/10` — cliente está desconectado da tailnet (`tailscale status` não mostra `vps-prod` ativo).

Ver `Magic DNS e extra_records` abaixo para o mecanismo detalhado.

### Headscale não responde

```bash
ssh deploy@187.127.6.20
docker ps | grep headscale          # confirmar que tá rodando
docker logs --tail=50 headscale     # ver erro
docker restart headscale
```

ACL inválido é causa comum (Headscale recusa subir). Se mudou `acl.json.j2`, validar JSON antes de aplicar.

### Magic DNS e extra_records

O Headscale tem um servidor DNS interno que distribui resoluções customizadas para os clientes Tailscale conectados (com `--accept-dns=true`, default). Isso é o **Magic DNS** — equivalente self-hosted da feature do Tailscale SaaS.

Configuração fica em [`roles/headscale/defaults/main.yml`](../roles/headscale/defaults/main.yml):

```yaml
headscale_extra_dns_records:
  - name: vault.aerobi.com.br
    type: A
    value: 100.64.0.1
  - name: s3-console.aerobi.com.br
    type: A
    value: 100.64.0.1
  - name: status.aerobi.com.br
    type: A
    value: 100.64.0.1
  - name: sftp.aerobi.com.br
    type: A
    value: 100.64.0.1
```

### Por que isso é necessário para vhosts tailnet-only

O bloco nginx `allow 100.64.0.0/10; deny all;` filtra por `$remote_addr` — o IP de origem do TCP. Para o nginx ver um IP CGNAT (`100.64.x.y`), o cliente precisa entrar via interface `tailscale0`, não via internet pública. Isso depende de qual IP o cliente resolve para o domínio:

| DNS resolve para | Rota do cliente | `$remote_addr` no nginx | Resultado |
| --- | --- | --- | --- |
| `187.127.6.20` (público) | eth0 do laptop → internet | IP público do laptop | **403** (não está em `100.64.0.0/10`) |
| `100.64.0.1` (tailnet) | `tailscale0` → VPS | IP CGNAT do laptop | **200** (passa no allow) |

Sem o `extra_records`, mesmo com `tailscale up`, o DNS público resolve para `187.127.6.20` e o cliente nunca usa a tailnet para esse tráfego.

### Quando adicionar uma entrada nova

Sempre que um novo serviço receber `vhost_tailnet_only=true` em `setup_app.yml`. Procedimento completo em [`DOMINIOS.md`](DOMINIOS.md#adicionar-um-serviço-de-infra-novo) (item 5).

Aplicar mudanças em `extra_records` requer:

```bash
ansible-playbook playbooks/setup_headscale.yml
```

A role regenera `/etc/headscale/config.yaml` no host, e o handler reinicia o container do Headscale. Clientes pegam a nova entrada nos próximos segundos (sem precisar reconectar).

Validar de um cliente na tailnet:

```bash
# 100.100.100.100 é o resolver "interno" do Tailscale.
# Quando --accept-dns=true, queries para domínios cobertos
# pelo Magic DNS passam por ele.
dig +short <sub>.aerobi.com.br @100.100.100.100   # esperado: 100.64.0.1
```

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
