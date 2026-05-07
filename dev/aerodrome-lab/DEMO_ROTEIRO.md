# Roteiro — videochamada com Eduardo (demo do Ansible)

Roteiro do que falar e demonstrar pra Eduardo durante a videochamada (~20 min). Objetivo: mostrar que o que ele fez à mão a gente já tem automatizado em Ansible, idempotente, versionado, e perguntar se ele topa adotar.

---

## Antes da chamada (5 min de preparação)

Tem o lab funcionando na sua máquina? Se não:

```bash
cd /home/elvis/aerobi-projects/aerobi-ansible/dev/aerodrome-lab
make clean         # reset total
make up            # sobe lab limpo (raspi-sim + 4 fake-cameras)
```

Abrir terminal pra compartilhar tela. Ter aberto:
- Esse roteiro pra consultar
- O `MANUAL_INSTALL.md` (mostrar na hora se ele quiser ver os comandos shell)
- Browser em https://github.com/atzaero/aerobi-ansible/pull/14 (PR pra mostrar o trabalho)

---

## Abertura (2 min) — reconhecer o trabalho dele

> "Eduardo, top que você instalou o mediamtx no Raspi e mandou as URLs RTSP. Vi inclusive que você descobriu a parte do `sourceOnDemand` — que é exatamente onde a maioria escorrega. Quero te mostrar uma coisa que a gente montou aqui que automatiza tudo isso. Achei que pode te economizar tempo nos próximos aeródromos."

**Não falar:** "você fez errado", "manual é ruim", "use ansible obrigado". Reconhece o trabalho dele primeiro.

---

## Parte 1 — O problema que o Ansible resolve (3 min)

> "Quando a gente vai instalar o segundo, terceiro, quarto aeródromo, você não vai querer ficar copiando comando por comando do zero. Plus: vai esquecer detalhe e cada Raspi vai virar um floquinho de neve. O Ansible deixa essa instalação **escrita uma vez, executável N vezes, sempre idêntica**."

Mostrar visualmente:

```
Hoje (manual)                  Com Ansible
─────────────────              ─────────────────
Raspi 1: comandos via SSH      Raspi 1: ansible-playbook -i ...
Raspi 2: comandos de novo      Raspi 2: ansible-playbook -i ...
Raspi 3: comandos de novo      Raspi 3: ansible-playbook -i ...
                               
risco: esquecer flag,          risco: zero — config no git
versão diferente,
                               vantagem: mudança vira commit
sourceOnDemand esquecido       que aplica em todos com 1 cmd
```

> "E mais importante: vira código, fica no git, qualquer um do time consegue refazer ou auditar."

---

## Parte 2 — Demo do lab (7 min) — compartilhar tela

### 2.1 Mostrar o lab parado

```bash
docker ps --filter "name=aerobi-lab"
# 5 containers: raspi-sim + 4 cam-N
```

> "Esse `raspi-sim` é um container Ubuntu 24.04 com SSH — simula seu Raspi físico. As 4 cam-N rodam ffmpeg testsrc + mediamtx, simulando câmeras Intelbras servindo RTSP. Bridge Docker 192.168.68.0/24, IPs fixos como na rede de aeródromo real."

### 2.2 Mostrar que raspi-sim está virgem

```bash
make ssh
which mediamtx           # → not found (esperado)
ls /etc/mediamtx 2>&1    # → No such file (esperado)
exit
```

> "Zero mediamtx, zero config, zero nada. Como ficaria seu Raspi recém-flashado com Ubuntu Server."

### 2.3 Rodar o playbook DO LAPTOP

> "Agora rodando o ansible **do meu laptop**, ele conecta via SSH no raspi-sim e instala tudo. O Raspi não precisa nem ter ansible instalado."

```bash
make playbook
# Mostrar o output das 19 tasks rolando.
# Pontos pra comentar enquanto roda:
# - "TASK [aerodrome_edge : Persistir IP forwarding via sysctl.d]" → o sysctl que você fez na mão
# - "TASK [mediamtx : Baixar tarball mediamtx v1.18.1]" → o curl que você fez
# - "TASK [mediamtx : Renderizar /etc/mediamtx/mediamtx.yml]" → o tee config que você fez
# - "TASK [mediamtx : Habilitar e iniciar mediamtx]" → systemctl enable + start
# - "TASK [Smoke test — mediamtx atendendo na porta HLS]" → bonus, valida que tá servindo
```

### 2.4 Ressaltar idempotência

```bash
make playbook   # rodar de novo
# Mostra: ok=12  changed=0
```

> "Olha — segunda vez rodou, `changed=0`. Não fez nada porque o estado já está como deveria. Diferente de script shell, que mexe toda vez. Posso rodar 50 vezes — só faz mudança se algo divergir."

### 2.5 Mostrar o estado final no raspi-sim

```bash
make ssh
mediamtx --version                       # v1.18.1
sudo systemctl is-active mediamtx        # active
sudo cat /etc/mediamtx/mediamtx.yml | head -40
# → mostrar que tem sourceOnDemand: yes em todos os paths
exit

# Confirmar HLS servindo (do raspi-sim, mas via túnel)
curl -sL http://localhost:8888/cam-1/index.m3u8 2>/dev/null || \
  ssh -i ssh/id_ed25519 -p 2222 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      deploy@localhost "curl -sL http://localhost:8888/cam-1/index.m3u8 | head -5"
```

> "Mediamtx subiu, está como service systemd que reinicia sozinho se travar, e já está servindo HLS pras 4 câmeras."

---

## Parte 3 — Ressaltando o `sourceOnDemand` (2 min)

> "Olha um detalhe legal: você descobriu na mão o `sourceOnDemand`. A nossa role já tem isso por padrão. Te mostro:"

Compartilhar `roles/mediamtx/defaults/main.yml`:

```yaml
mediamtx_source_on_demand: true
mediamtx_source_on_demand_start_timeout: 10s
mediamtx_source_on_demand_close_after: 10s
```

> "Default true. Se algum dia alguém quiser mudar, faz override no `inventory/<aeródromo>/group_vars`. Inclusive coloquei comentário no código referenciando o problema que você teve hoje. Se o setup tivesse passado pelo nosso ansible, você teria pulado essa dor."

---

## Parte 4 — Como você usaria isso amanhã (3 min)

### Hoje (manual)

> "Hoje você faria: SSH no Raspi, apt install, baixar mediamtx, criar config, criar systemd unit, configurar, sysctl, testar."

### Com nosso ansible

> "Com o ansible:"

```bash
# No teu laptop:
cd ~/aerobi-projects/aerobi-ansible

# 1. Criar inventory pro aeródromo novo (vou te ajudar na primeira vez)
mkdir -p inventory/aerodromes/aero-mvp
# inventory/aerodromes/aero-mvp/hosts.yml — IP do raspi
# inventory/aerodromes/aero-mvp/group_vars/all.yml — IPs das câmeras

# 2. Pegar pre-auth key Tailscale tag:airfield (Elvis gera na VPS)

# 3. Rodar
ansible-playbook -i inventory/aerodromes/aero-mvp playbooks/setup_aerodrome.yml

# Pronto. Raspi configurado em ~30 segundos.
```

Quando precisa atualizar versão do mediamtx em todos aeródromos: muda 1 var, roda em todos.

> "Pra mudar a versão do mediamtx em todos aeródromos: edita 1 linha no `roles/mediamtx/defaults/main.yml`, roda contra todos. Pronto."

---

## Parte 5 — A pergunta (3 min)

> "Sobre o aeródromo MVP que você está montando agora — você quer:
>
> **(a)** continuar manual nesse, e a gente usa o ansible só nos próximos. Sem problema.
>
> **(b)** rodar o ansible agora contra o seu Raspi atual. Como o ansible é idempotente, ele detecta o que já tá instalado e só ajusta o que faltar pra bater com nosso template (uniformizar config, criar user mediamtx do jeito que a gente padronizou, etc.). Pode dar 'changed' em algumas coisas, mas nada destrutivo.
>
> **(c)** começar do zero esse aeródromo: derruba sua instalação manual, deixa Raspi limpo, eu/ele roda o ansible. Mais limpo do ponto de vista 'idêntico ao que a gente vai fazer nos próximos'.
>
> Qual prefere?"

**Não pressionar.** Se ele quiser (a), tudo bem — o que ele fez funciona.

### Possíveis perguntas dele

| Pergunta | Resposta |
|---|---|
| "E se eu já tiver mediamtx versão diferente?" | Ansible compara versão. Se já bater, não baixa. Se não bater, atualiza pacificamente (download + restart). |
| "Posso usar minha convenção de paths (atzW/S/N/E)?" | Sim. É só var: `mediamtx_paths` no `inventory/<aerodromo>/group_vars/all.yml`. Aceita qualquer nome. |
| "Quem mexe nas roles?" | Quem vai mexer faz PR no `aerobi-ansible` → review → merge. Mudanças versionadas. |
| "E se eu precisar de algo customizado de aeródromo X?" | Override no inventory, sem mexer na role base. |
| "Tailscale: como pego a pre-auth key?" | Eu (Elvis) gero na VPS Aerobi com `headscale preauthkeys create --user 1 --tags tag:airfield --expiration 30d`. Te passo via Vaultwarden Send. |
| "Tem como rodar de dentro do Raspi (sem ansible no laptop)?" | Tecnicamente sim (ansible-pull), mas a gente padronizou em rodar do laptop. Mais centralizado, audit melhor, Raspi não precisa nem ter ansible. |

---

## Encerramento (1 min)

> "Resumo: o lab está aqui na minha máquina, validado, idempotente. PR aberto em [link]. Quando você decidir o caminho que prefere, me avisa que a gente ajusta. Próximo aeródromo já vai dar pra fazer em um comando."

---

## Pós-chamada — capturar o que ficou decidido

- Qual opção (a/b/c) ele topou?
- Algum override que ele pediu (paths customizados? versão diferente?)
- Próximo passo combinado (ele aplica nesse Raspi? a gente faz juntos remoto via tailnet quando ele subir?)
- Atualizar issue do GitHub com a decisão

---

## Cheat sheet de comandos pra mostrar (cole no chat se precisar)

```bash
# Subir lab
cd ~/aerobi-projects/aerobi-ansible/dev/aerodrome-lab && make up

# Ver status
make status

# Entrar no raspi-sim "virgem"
make ssh

# Rodar ansible do laptop pro raspi-sim
make playbook

# Confirmar idempotência
make playbook   # changed=0 esperado

# Ver HLS servindo
make ssh
curl -sL http://localhost:8888/cam-1/index.m3u8 | head -5

# Derrubar
make down
```
