# Research: VPN privada para a VPS Aerobi

**Tipo:** Research / Spike — comparar, decidir, gerar issue de implementação se aprovado.

**Status:** Concluído. Recomendação: **Headscale self-hosted desde o início**, rodando na própria VPS Aerobi sob `headscale.aerobi.com.br`.

**Referência:** este documento espelha o deliverable da issue [elvisea/ansible-vps#44](https://github.com/elvisea/ansible-vps/issues/44), adaptado ao contexto da VPS Aerobi e ao caso de uso de câmeras em aeródromos.

---

## 1. Motivação

Hoje a VPS Aerobi (`187.127.6.20`) já tem um footprint privado bom: aplicação, banco e cofre rodam todos em `127.0.0.1:PORT`, atrás do Nginx, com UFW restrito a 22/80/443. A única superfície administrativa exposta publicamente é `vault.aerobi.com.br/admin` (Vaultwarden, protegida por `ADMIN_TOKEN`). Trazer esse `/admin` pra trás de VPN reduz o risco de bruteforce e zero-day no painel — superfície pública é convite pra scanner automatizado, mesmo com senha forte.

Mas o que torna VPN um **pré-requisito** (e não otimização incremental) é o produto futuro: câmeras de segurança em aeródromos serão conectadas a um servidor local em cada aeródromo, e o backend Aerobi (na VPS) precisa acessar imagens dessas câmeras para servir ao frontend. Sem mesh VPN, ou (a) câmeras ficam expostas na internet pública com IP roteável e auth, ou (b) cada aeródromo precisa VPN site-to-site manual. Ambos são piores que mesh VPN. Adicionalmente, a VPN abre dois casos oportunistas: acesso direto ao Postgres via DBeaver (sem `ssh -L 5432`) e acesso ao painel Vaultwarden `/admin` pelo celular conectado à tailnet de qualquer rede (4G, Wi-Fi público).

## 2. Esclarecimento conceitual

Confusão fácil de cometer e que merece explicitação:

- **Tailscale = SaaS.** O control plane (autenticação, ACLs, coordenação de chaves) roda na infra da Tailscale Inc. Os clientes WireGuard rodam nos dispositivos, mas dependem do control plane gerenciado por terceiros. Free tier 100 devices / 3 users; depois plano pago.
- **Headscale = self-hosted control plane.** Reusa os **mesmos** clientes Tailscale, mas o control plane você opera. Sem cap artificial, sem dependência de terceiros, dados de telemetria de presença ficam internos. Custo: backup de DB, atualização do binário, gestão de pre-auth keys via CLI.
- **WireGuard puro = só o protocolo.** Sem control plane — você gerencia configs por peer manualmente.
- **Netbird = mesh OSS-completo concorrente do Tailscale**, com control plane self-hostable.

A pergunta "Tailscale self-hosted" não tem resposta — os clientes Tailscale são abertos, mas o control plane é da empresa. A versão self-hosted equivalente é Headscale (compatível com os mesmos clientes).

## 3. Critérios de avaliação

Adaptados ao caso multi-site da Aerobi:

- **Setup por device** — laptop dev, celular, **servidor de aeródromo Linux** (provisionado remotamente).
- **NAT traversal** — servidores em aeroportos provavelmente atrás de CGNAT do provedor local.
- **Subnet routing** — servidor local de aeródromo deve anunciar a subnet de câmeras IP, sem precisar instalar cliente em cada câmera.
- **ACLs** — backend Aerobi acessa câmeras de qualquer aeródromo; aeródromo A não fala com aeródromo B.
- **Mobile clients** (iOS/Android) — para inspeção/admin remoto.
- **Performance** — throughput de stream RTSP/MJPEG via VPN.
- **Self-hostable end-to-end** — lock-in de vendor, compliance/LGPD em setor aviação.
- **Pricing futuro** se passar do free tier (projeção: 50–100 devices em 2–3 anos).
- **Compatibilidade com fluxo existente** — DBeaver via SSH tunnel hoje, deploy via SSH público (CI/CD GitHub Actions).

## 4. Tabela comparativa

| Tool | Modelo | Setup | NAT traversal | Subnet routing | ACL | Custo operacional | Trade-off principal |
|---|---|---|---|---|---|---|---|
| **Tailscale** | Mesh, control plane SaaS | 1 cmd/device | Excelente (DERP relays globais inclusos) | Sim (`--advertise-routes`) | ACL JSON via UI | Zero | Free 100 devices/3 users; SaaS dependency, dados de presença na Tailscale Inc. |
| **Headscale** | Self-hosted control plane Tailscale | Médio (container + DB + Nginx + cert) | Mesmo do Tailscale (clientes iguais; sem DERP próprio usa relays públicos do Tailscale, oficialmente não suportado mas funcional) | Sim | ACL JSON (compatível Tailscale) | Backup DB + updates binário | Operação extra mas: sem cap, sem SaaS, dados internos |
| **WireGuard** puro | VPN ponto-a-ponto clássica | Manual por peer | Ruim atrás de CGNAT sem relay próprio | Manual via `AllowedIPs` | Via firewall iptables | Alto pra mesh dinâmica | Reinventa o que Tailscale dá grátis |
| **Netbird** | Mesh OSS-completo | Médio (similar Headscale) | Bom (STUN/TURN próprio) | Sim | ACL via UI | Similar Headscale | Ecosistema menos maduro que Tailscale (clientes mobile, longevidade) |

## 5. Recomendação — Headscale self-hosted

**Por quê Headscale (e não Tailscale SaaS):**

- **Sem cap de 100 devices.** N aeródromos × 1–2 devices cada → projeção de 50–100 devices em 2–3 anos é alcançável. Tailscale free não cobre indefinidamente, paid plan adiciona custo recorrente.
- **Sem dependência SaaS.** Compliance/LGPD em setor aviação — metadados de presença e routing ficam dentro de casa.
- **Migração futura é zero-friction porque é o mesmo cliente Tailscale.** Se decidirmos voltar pro SaaS algum dia, é troca de `--login-server` em cada nó, não rip-and-replace.
- **Custo operacional é absorvível.** A VPS Aerobi tem 15 GB de RAM, 14 GB livres. Headscale consome ~30–80 MB.

**Por quê NÃO Tailscale (mesmo SaaS sendo mais simples):**

O caminho da issue #44 do bytefulcode ("começar SaaS, migrar quando crescer") faz sentido pra um único site. Pro caso aerobi com N aeródromos crescentes, é só adiar a dor de migrar — sem ganho real, dado que Headscale roda no servidor que já temos, com complexidade marginal.

**Por quê NÃO WireGuard puro:**

Mesh dinâmica entre N aeródromos atrás de CGNAT exigiria operar relay STUN/TURN próprio, gerar/distribuir configs por peer, e re-emitir manualmente quando um nó troca de IP. Reinventar o que Headscale (com clientes Tailscale) já entrega. Vale só se o requisito for "zero dependência de qualquer ferramenta além de WireGuard kernel" — não é o caso.

**Por quê NÃO Netbird:**

Alternativa válida. Mas ecosistema menos maduro que Tailscale, especialmente clientes mobile e operação de longo prazo. Vale revisitar daqui 2–3 anos se algo no tooling Tailscale degradar.

## 6. Arquitetura proposta — Headscale na VPS Aerobi

### Componentes

- Container `headscale/headscale:latest` — control plane.
- **DB:** reusar Postgres existente (`postgres:17` em `127.0.0.1:5432`). Criar database e user `headscale` via role `postgres_databases`. Evita SQLite e permite backup junto com os outros bancos.
- **Bind:** `127.0.0.1:8080` (Headscale HTTP API).
- **Nginx reverse proxy:** vhost novo `headscale.aerobi.com.br` → `127.0.0.1:8080`, TLS via Certbot. Aproveita `roles/nginx_vhost` existente.
- **DERP:** decisão deferida. Inicialmente usar relays públicos do Tailscale (funciona; oficialmente não suportado mas operável). Se virar problema (latência, bloqueio), rodar DERP server embedded do próprio Headscale.
- **UFW:** abrir UDP **41641** (entrada padrão WireGuard nos clientes Tailscale). Headscale HTTP fica atrás do Nginx 443 — sem porta extra em TCP.

### Em cada nó cliente

VPS, laptop dev, celular, servidor de aeródromo:

```
tailscale up \
  --login-server=https://headscale.aerobi.com.br \
  --authkey=<preauth-key> \
  --hostname=<nome-do-no>
```

Pre-auth keys geradas no Headscale via CLI:

```
docker exec headscale headscale users create aerobi
docker exec headscale headscale preauthkeys create --user aerobi --reusable --expiration 90d
```

### Tags e ACLs propostas

Tags:

- `tag:vps` — VPS Aerobi (backend)
- `tag:airfield` — servidores de aeródromo
- `tag:dev` — laptops/celulares dev/admin

Regras (formato Tailscale ACL JSON):

- `tag:vps` → `tag:airfield` (backend acessa câmeras via subnet anunciada)
- `tag:dev` → `*` (admin acessa tudo)
- `tag:airfield` ↔ `tag:airfield` — **deny** (aeródromos isolados entre si)
- `tag:airfield` → `tag:vps` — **deny** (servidor de aeródromo recebe conexão, não inicia)

## 7. Plano de migração de serviços

### Fase A — VPS + dev (PoC inicial)

1. Subir Headscale na VPS Aerobi sob `headscale.aerobi.com.br`.
2. Criar user `aerobi` e pre-auth keys. Conectar VPS Aerobi, laptop dev e celular na tailnet.
3. Mover Vaultwarden `/admin` pra trás de `allow 100.64.0.0/10; deny all;` no `location /admin`. Login `/` segue público (extensão Bitwarden e app mobile precisam).
4. **Postgres atrás da VPN** — ajustar bind do container Postgres para também escutar no IP da interface `tailscale0` (além de `127.0.0.1`). DBeaver passa a conectar direto pelo IP Tailscale da VPS, sem `ssh -L 5432:...`.

   **Detalhe técnico:** a interface `tailscale0` só existe depois que o cliente Tailscale conectou ao Headscale, então a ordem de boot importa. Duas abordagens possíveis (decidir na issue de implementação):

   - **Recomendada:** manter Postgres bindado em `127.0.0.1:5432` no container e adicionar regra UFW `allow in on tailscale0 to any port 5432`, mais bind `0.0.0.0:5432` filtrado por iptables/ufw. Mais robusto contra reordenação de boot.
   - **Alternativa:** bind explícito duplo `127.0.0.1:5432` + `100.x.x.x:5432` no docker-compose, com `systemd` dependency em `tailscaled.service`. Frágil em redeploys do container.

### Fase B — Aeródromos (caso de uso real, futuro)

1. Provisionar servidor local em cada aeródromo (Ubuntu/Debian via role Ansible separada — fora do escopo deste repo provavelmente).
2. Cliente Tailscale apontando pra `headscale.aerobi.com.br` com tag `tag:airfield`.
3. `tailscale up --advertise-routes=192.168.X.0/24` — anunciar subnet das câmeras IP locais. X depende do plano de endereçamento de cada aeródromo (definir com a equipe de campo).
4. Backend Aerobi acessa cada câmera via IP da subnet anunciada pela tailnet.

### O que continua público (não muda)

- `aerobi.com.br` (frontend futuro) — usuário final.
- `api.aerobi.com.br/` — frontend e clientes externos consomem.
- `vault.aerobi.com.br/` (login do Vaultwarden) — extensão Bitwarden e app mobile precisam.
- `headscale.aerobi.com.br` — precisa estar acessível pra clientes da tailnet conectarem; autenticação é via pre-auth key, não por exposição.
- SSH `:22` — CI/CD via GitHub Actions usa SSH público. Mantido como está.

### O que vai pra trás da VPN

- `vault.aerobi.com.br/admin` (location-based ACL no Nginx).
- **Postgres** — acesso DBeaver direto pelo IP Tailscale da VPS, sem SSH tunnel.
- Câmeras IP em aeródromos — backend acessa via subnet route anunciada.
- Painéis admin futuros (Portainer, Grafana, etc.) — nascer já privados.

## 8. Footprint na VPS Aerobi

- Container Headscale: ~30–80 MB RAM.
- DB Headscale no Postgres existente: ~50 MB inicial, cresce com nº de devices/keys (negligível).
- Cliente Tailscale na VPS: ~30 MB RAM, módulo WireGuard no kernel (zero overhead de CPU).
- **Total:** <200 MB RAM extras nos 14 GB livres atuais. Insignificante.

## 9. Riscos e mitigações

- **Headscale como SPOF.** Se a VPS cair, novos devices não conseguem entrar na tailnet; conexões existentes continuam funcionando (chaves WireGuard já trocadas). Mitigação: backup diário do DB junto com Postgres; rebuild rápido via Ansible. Eventualmente — se justificar — mover Headscale pra VPS dedicada.
- **Manutenção do Headscale.** Container OSS, manutenção comunitária. Risco baixo (>20k stars no GitHub, releases regulares). Plano B em pior caso: voltar pra Tailscale SaaS — basta trocar `--login-server` em cada nó.
- **DERP via relays públicos do Tailscale.** Oficialmente não suportado pra clientes fora do control plane Tailscale. Funciona hoje, pode parar amanhã. Plano B: rodar DERP server embedded do próprio Headscale (suporte built-in).
- **Tag `tag:airfield` → câmeras.** Subnet routing dá acesso à subnet inteira da rede local do aeródromo. Garantir que essa rede não tenha outros recursos sensíveis além das câmeras (definir com equipe de campo no momento do provisionamento).

## 10. Próximos passos

Após aprovação deste research, abrir **issue de implementação** no repo `aerobi-ansible` cobrindo:

1. Role Ansible `headscale` (container + db migration + nginx vhost + UFW UDP 41641).
2. Role Ansible `tailscale_client` (instala cliente, conecta no Headscale com authkey vault).
3. Ajuste em `roles/vaultwarden/templates/vhost.conf.j2` para `allow 100.64.0.0/10; deny all;` no `/admin`.
4. Ajuste em Postgres pra expor `5432` em `tailscale0` (decidir estratégia: UFW filter ou bind duplo).
5. Definição inicial das tags ACL e geração de pre-auth keys (vault Ansible).
6. Integração no `playbooks/setup_vps.yml`.

Issue separada (provavelmente em outro repo) cobrirá o provisionamento dos servidores de aeródromo.

---

**Tempo estimado de implementação:** 4–6h para Fase A (role + integração + PoC com VPS + laptop + celular). Fase B depende do cronograma do produto câmeras-em-aeródromos.
