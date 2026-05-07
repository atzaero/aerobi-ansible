# Aerodrome Lab — laboratório local de simulação de aeródromo edge

Esse laboratório sobe um ambiente Docker que reproduz o cenário de um aeródromo real (Raspberry Pi + 4 câmeras IP) inteiramente na sua máquina, sem hardware. Serve para:

- Testar `setup_aerodrome.yml` antes de aplicar em Raspi físico
- Iterar nas roles `mediamtx` e `aerodrome_edge` durante desenvolvimento
- Documentação executável: o operador novo segue os mesmos comandos no lab e no campo

```
                  Sua máquina (host)
   ┌──────────────────────────────────────────────────┐
   │                                                  │
   │  ansible-playbook → SSH (porta 2222)             │
   │                       │                          │
   │                       ▼                          │
   │   ┌────────────── Docker bridge ──────────────┐  │
   │   │  192.168.68.0/24 (rede do "aeródromo")    │  │
   │   │                                           │  │
   │   │   raspi-sim       cam-1   cam-2   cam-3   │  │
   │   │   .68.10          .91     .92     .93     │  │
   │   │                              cam-4 .94    │  │
   │   │   (Ubuntu+SSH)    (mediamtx + ffmpeg      │  │
   │   │                    testsrc, RTSP :8554)   │  │
   │   └───────────────────────────────────────────┘  │
   │                                                  │
   └──────────────────────────────────────────────────┘
```

---

## Pré-requisitos

- Docker Engine 24+ e Docker Compose v2 (`docker compose version`)
- Ansible 2.15+ (`ansible --version`)
- 1 GB de RAM livre, 1 GB de disco para imagens
- Linux ou macOS (Windows via WSL2 deve funcionar mas não foi testado)

---

## Quick start

```bash
cd dev/aerodrome-lab/

# 1. Subir o ambiente
make up
# → Gera chave SSH, builda imagem do raspi-sim, sobe 5 containers

# 2. Verificar que o Ansible alcança o raspi-sim
make smoketest
# → Esperado: "raspi-sim | SUCCESS => { 'ping': 'pong' }"

# 3. Entrar no raspi-sim (igual o Eduardo entraria no Raspi real)
make ssh
# → Você vira deploy@raspi-sim

# 4. Rodar o playbook setup_aerodrome.yml — DOIS MODOS:

#   Modo A) Agentless / push (padrão produção): roda DO LAPTOP via SSH
make playbook
# → ansible-playbook do host conecta via SSH no raspi-sim e instala
#   aerodrome_edge (sem tailscale no lab) + mediamtx + 4 paths das câmeras

#   Modo B) Pull / -c local (didático): roda DE DENTRO do raspi-sim
make playbook-local
# → docker exec entra no container e roda ansible-playbook lá dentro,
#   contra localhost (-c local). Mesmo resultado final, jeito diferente.

# 5. Validar fan-out das câmeras (do raspi-sim para as fake-cameras)
make camera-test

# 6. Derrubar tudo
make down

# Reset total (apaga chaves SSH também):
make clean
```

### Os dois modos do Ansible — quando usar cada

```
Modo A (push)                     Modo B (pull)
┌────────────┐                    ┌──────────────┐
│  Laptop    │                    │  raspi-sim   │
│            │  ─SSH─►            │              │
│ ansible-   │      [raspi-sim]   │  ansible-    │
│  playbook  │                    │   playbook   │
│            │                    │   -c local   │
└────────────┘                    └──────────────┘
make playbook                     make playbook-local
```

| Modo | Quando usar |
|---|---|
| **A — push (`make playbook`)** | Padrão produção. Operador roda do laptop, atinge N raspis em paralelo, atualizações centralizadas, Raspi não precisa ter ansible instalado. |
| **B — pull (`make playbook-local`)** | Bootstrap inicial via cloud-init/ansible-pull, treinamento de operador novo, demo didática. Operador entra no Raspi e roda ansible lá. |

Os dois rodam **as mesmas roles** e produzem **o mesmo estado final** — só muda quem invoca o `ansible-playbook`. Em produção, recomendamos modo A.

---

## O que cada componente representa no mundo real

| Container do lab | Equivalente em produção |
|---|---|
| `raspi-sim` | Raspberry Pi 4/5 instalado fisicamente no aeródromo |
| `cam-1` ... `cam-4` | Câmeras Intelbras IP em `192.168.68.91-94` |
| Bridge `aerobi-aerodrome-lab` | LAN do aeródromo (cabo Ethernet ou Wi-Fi) |
| Porta `2222` no host | Acesso SSH ao Raspi (em produção, via tailnet pelo hostname `aerobi-edge-mvp`) |

---

## Como o operador "atua" no lab

O fluxo é exatamente o mesmo que ele seguiria no campo:

```bash
# Do laptop dele (não do raspi-sim):
cd aerobi-ansible
ansible-playbook -i inventory/dev-aerodrome playbooks/setup_aerodrome.yml --skip-tags tailscale
```

A flag `--skip-tags tailscale` existe **apenas no lab** porque a role `aerodrome_edge` em produção configura o cliente Tailscale, e Tailscale dentro de container Docker exige permissões adicionais (TUN, NET_ADMIN) que evitamos aqui pra manter o lab simples e seguro. Em produção (Raspi real), nenhuma flag é necessária — Tailscale roda nativo no host.

---

## Limitações conhecidas

| Limitação | Por quê | Workaround |
|---|---|---|
| Sem Tailscale no raspi-sim | Container precisa `--privileged` + `/dev/net/tun` + Headscale acessível; complica debugging | Use `--skip-tags tailscale` (ambos `make playbook` e `make playbook-local` já fazem). Valide Tailscale só no Raspi físico. |
| Câmera fake usa porta 8554 RTSP | Câmera Intelbras real usa 554. ffmpeg rodando como non-root no container não consegue bindar < 1024. | Em produção a porta 554 funciona normal. O lab usa 8554 nas vars do inventory `dev-aerodrome`. |
| Sem áudio nas câmeras fake | `testsrc` é vídeo puro. Câmera real Intelbras tem áudio AAC. | Não relevante pra MVP de monitoramento visual. |
| Resolução 640×480 nas câmeras fake | CPU local não justifica 1080p para teste de pipeline | Câmera real entrega 1080p H.264 4 Mbps. mediamtx faz remux passthrough — tanto faz a resolução. |
| `raspi-sim` é amd64/arm64 (do host), Raspi real é arm64 | Imagem `geerlingguy/docker-ubuntu2404-ansible` é multi-arch | Algumas tasks que dependem de detecção de arquitetura podem precisar ajuste — testar role com `ansible_architecture` em condicionais. |

---

## Troubleshooting

### `make up` falha em "permission denied" no /sys/fs/cgroup

Você está num kernel antigo ou Docker mal configurado. Confirme:

```bash
docker info | grep -i cgroup
# Esperado: cgroup version: 2
```

Em distros antigas, edite `/etc/default/grub` adicionando `systemd.unified_cgroup_hierarchy=1` e re-instale grub.

### `make ssh` retorna "Connection refused"

Container ainda subindo. SSH demora ~5s pra ficar pronto. Roda `make status` e espera `raspi-sim` ficar em estado `running` por uns segundos.

### `make playbook` reclama que o playbook não existe

As roles `aerodrome_edge` (#9) e `mediamtx` (#8) e o playbook `setup_aerodrome.yml` (#10) estão como issues abertas, ainda não implementadas. Esse Makefile target só vai funcionar plenamente depois que essas issues forem mergeadas. Use `make smoketest` enquanto isso para validar que o lab está funcional.

### Câmera não responde em `rtsp://192.168.68.91:8554/cam-1`

Conferir log do container:

```bash
docker compose logs cam-1
# Procurar por "ffmpeg" e "Stream mapping"
```

Se ffmpeg não subiu, geralmente é falta da imagem `latest-ffmpeg`. Confirme:

```bash
docker pull bluenviron/mediamtx:latest-ffmpeg
```

### Como debugar dentro do raspi-sim?

```bash
make ssh
# Já está como deploy. Pra root:
sudo -i
# Verificar processos systemd:
systemctl list-units --type=service --state=running
# Tentar alcançar uma câmera:
ping 192.168.68.91
curl -v rtsp://192.168.68.91:8554/cam-1
```

---

## Como o Eduardo (ou qualquer dev novo) usa isso

O fluxo recomendado quando alguém novo entra:

1. Clona `aerobi-ansible`, `cd dev/aerodrome-lab/`
2. `make up`
3. Lê esse README
4. Roda `make ssh`, explora o "Raspi simulado"
5. Roda `make playbook` — vê o Ansible operar de fora
6. Compara com `playbooks/setup_aerodrome.yml` pra entender o que cada role fez
7. Quando confiante, aplica em Raspi real seguindo `docs/AERODROMO.md`

---

## Estrutura de arquivos do lab

```
dev/aerodrome-lab/
├── docker-compose.yml          # Define raspi-sim + 4 cameras + bridge 192.168.68.0/24
├── Makefile                    # up/down/ssh/playbook/clean/...
├── README.md                   # Este arquivo
├── raspi-sim/
│   └── Dockerfile              # Ubuntu 24.04 + openssh + deploy user + chave SSH
├── fake-camera/
│   └── mediamtx.yml            # Config do mediamtx interno de cada câmera
└── ssh/                        # Chaves SSH efêmeras (gitignored)
    ├── .gitignore
    ├── id_ed25519              # gerada por 'make keys'
    ├── id_ed25519.pub
    └── authorized_keys

inventory/dev-aerodrome/
├── hosts.yml                   # raspi-sim em localhost:2222
└── group_vars/
    └── all.yml                 # aerodrome_id, camera_subnets, mediamtx_paths
```

---

## Próximos passos

- [ ] Implementar role `mediamtx` (#8) e validar `make playbook` instala mediamtx no raspi-sim
- [ ] Implementar role `aerodrome_edge` (#9) com `--skip-tags tailscale` funcional
- [ ] Implementar `setup_aerodrome.yml` (#10) e revalidar `make playbook` end-to-end
- [ ] Adicionar smoke test ansible que valida `mediamtx` está servindo HLS após playbook (`curl http://raspi-sim:8888/cam-1/index.m3u8` retorna m3u8 válido)
- [ ] Fase 2 (opcional, fora do MVP): adicionar Tailscale dentro do raspi-sim conectando ao Headscale de dev/staging, removendo `--skip-tags tailscale`

---

## Referências

- Issue desta implementação: atzaero/aerobi-ansible#13
- Épica: atzaero/aerobi-poc#1
- Doc de arquitetura: [`aerobi-poc/ARQUITETURA_STREAMING.md`](https://github.com/atzaero/aerobi-poc/blob/main/ARQUITETURA_STREAMING.md)
- Molecule (testes de role isoladas): [`docs/MOLECULE.md`](../../docs/MOLECULE.md)
