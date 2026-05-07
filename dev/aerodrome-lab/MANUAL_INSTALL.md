# Guia manual: instalar mediamtx no "Raspi" passo a passo

Este guia é a **versão hands-on** do que o Ansible vai automatizar nas roles `mediamtx` (#8) e `aerodrome_edge` (#9). Você vai conectar no `raspi-sim` via SSH e executar os comandos um a um, exatamente como faria num Raspberry Pi físico no aeródromo.

**Objetivos:**
- Entender o que cada role do Ansible faz por baixo dos panos
- Validar end-to-end que o pipeline câmera → mediamtx → HLS funciona
- Servir como referência implementável quando for escrever as roles

> **Pré-requisito**: o lab precisa estar rodando. Se ainda não, faça `make up` no diretório `dev/aerodrome-lab/`.

---

## Passo 0 — Conectar no raspi-sim

Do seu laptop (host):

```bash
cd dev/aerodrome-lab/
make ssh
```

Você cai num shell `deploy@raspi-sim:~$`. A partir daqui, tudo que você digitar acontece **dentro do "Raspi"**.

Confere o ambiente:

```bash
whoami           # deploy
hostname         # raspi-sim
uname -m         # x86_64 (em Raspi real seria aarch64)
cat /etc/os-release | grep PRETTY  # Ubuntu 24.04 LTS
```

---

## Passo 1 — Atualizar o sistema e instalar utilitários básicos

Equivale ao que a role `common` do Ansible faz.

```bash
sudo apt-get update
sudo apt-get install -y \
    curl \
    ca-certificates \
    ffmpeg \
    iputils-ping \
    net-tools
```

`ffmpeg` aqui é só pra você poder rodar `ffprobe` depois e validar que as câmeras servem stream H264 válido. Em produção o Raspi não precisa de ffmpeg (mediamtx não usa pra remux puro).

---

## Passo 2 — Validar que o "Raspi" alcança as 4 câmeras

Antes de instalar nada, valida que a rede está OK. As câmeras fake estão em `192.168.68.91-94:8554/live`.

```bash
# Ping ICMP
for ip in 91 92 93 94; do
    ping -c 1 -W 1 192.168.68.$ip > /dev/null && echo "cam-$((ip-90))  ICMP OK" || echo "cam-$((ip-90))  ICMP FAIL"
done

# Probe RTSP TCP
for ip in 91 92 93 94; do
    timeout 1 bash -c "</dev/tcp/192.168.68.$ip/8554" 2>/dev/null && echo "cam-$((ip-90))  TCP 8554 OK" || echo "cam-$((ip-90))  TCP 8554 FAIL"
done

# Conectar de verdade no RTSP da cam-1 e ler metadados do stream
ffprobe -v error -i rtsp://192.168.68.91:8554/live -show_streams -of compact=p=0:nk=1 2>&1 | head -3
# Esperado: codec_type=video, codec_name=h264, width=640 height=480
```

Se algo aqui falhar, o resto não vai funcionar. Para `make down && make up` e tente de novo.

---

## Passo 3 — Habilitar IP forwarding no kernel

Em produção, o Raspi precisa fazer **subnet routing** — encaminhar pacotes da tailnet pra LAN local das câmeras. Pra isso o kernel precisa de IP forwarding ligado.

```bash
# Estado atual
sysctl net.ipv4.ip_forward
# Esperado: net.ipv4.ip_forward = 1 (no lab já vem ligado; em Raspi novo geralmente é 0)

# Habilitar em runtime (efeito imediato)
sudo sysctl -w net.ipv4.ip_forward=1
sudo sysctl -w net.ipv6.conf.all.forwarding=1

# Persistir entre reboots
sudo tee /etc/sysctl.d/99-aerobi-edge.conf > /dev/null <<EOF
# Aerobi edge — IP forwarding pro Tailscale subnet routing
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
EOF
sudo sysctl -p /etc/sysctl.d/99-aerobi-edge.conf
```

> **No lab isso já vem ativo** porque o container Docker tem privileges. Em Raspi físico esse passo é essencial.

---

## Passo 4 — Tailscale (PULAR no lab; fazer em produção)

Em Raspi físico você faria aqui:

```bash
# Instalar
curl -fsSL https://tailscale.com/install.sh | sh

# Conectar no Headscale Aerobi com pre-auth key tag:airfield
sudo tailscale up \
    --login-server=https://headscale.aerobi.com.br \
    --authkey=hskey-auth-... \
    --advertise-routes=192.168.68.91/32,192.168.68.92/32,192.168.68.93/32,192.168.68.94/32 \
    --hostname=$(hostname)

# Validar
sudo tailscale status
sudo tailscale ip -4   # esperar IP no range 100.64.0.x
```

**Pular no lab.** Tailscale dentro de container Docker exige `--privileged` + Headscale acessível, e atrapalha mais do que ajuda pro entendimento. Continue pra próxima parte.

Em paralelo (na VPS) você precisaria aprovar as rotas — só relevante em produção:

```bash
# Na VPS Aerobi (não no Raspi)
ssh deploy@187.127.6.20
docker exec headscale headscale nodes list-routes
docker exec headscale headscale nodes approve-routes \
    --identifier <ID-DO-RASPI> \
    --routes 192.168.68.91/32,192.168.68.92/32,192.168.68.93/32,192.168.68.94/32
```

---

## Passo 5 — Baixar e instalar mediamtx

mediamtx é distribuído como binário Go estático. Sem dependências, sem Docker, só baixar e rodar.

```bash
# Detectar arquitetura
ARCH=$(uname -m)
case "$ARCH" in
    x86_64)  MTX_ARCH=amd64 ;;
    aarch64) MTX_ARCH=arm64v8 ;;
    armv7l)  MTX_ARCH=armv7 ;;
    *) echo "Arch $ARCH não suportada"; exit 1 ;;
esac
echo "Arquitetura: $MTX_ARCH"

# Versão alvo (atualizar quando sair release nova)
MTX_VERSION=v1.18.1

# Baixar e extrair
cd /tmp
curl -fL -o mediamtx.tar.gz \
    "https://github.com/bluenviron/mediamtx/releases/download/${MTX_VERSION}/mediamtx_${MTX_VERSION}_linux_${MTX_ARCH}.tar.gz"
tar xzf mediamtx.tar.gz

# Instalar binário
sudo install -m 0755 mediamtx /usr/local/bin/mediamtx
mediamtx --version
# Esperado: v1.18.1
```

---

## Passo 6 — Configurar mediamtx (paths apontando pras câmeras)

```bash
# Criar diretório de config
sudo mkdir -p /etc/mediamtx

# Criar config que puxa as 4 câmeras fake e expõe HLS na 8888
sudo tee /etc/mediamtx/mediamtx.yml > /dev/null <<'EOF'
# Aerobi edge mediamtx — recebe RTSP das câmeras Intelbras locais
# e re-publica como HLS para o backend Aerobi consumir via tailnet.

logLevel: info
logDestinations: [stdout]

# RTSP — desabilitado: não somos servidor RTSP, somos cliente das câmeras
rtsp: no

# HLS — exposto na 8888, será acessível pela tailnet (em produção)
# No lab: localhost:8888 dentro do raspi-sim (não exposto no host)
hls: yes
hlsAddress: :8888
hlsAlwaysRemux: yes
hlsVariant: fmp4
hlsSegmentCount: 7
hlsSegmentDuration: 1s
hlsAllowOrigins: ["*"]

# WebRTC — desabilitado por enquanto (P1, fora do MVP)
webrtc: no
rtmp: no
srt: no

paths:
  cam-1:
    source: rtsp://192.168.68.91:8554/live
    rtspTransport: tcp
    sourceOnDemand: yes
    sourceOnDemandStartTimeout: 10s
    sourceOnDemandCloseAfter: 10s
  cam-2:
    source: rtsp://192.168.68.92:8554/live
    rtspTransport: tcp
    sourceOnDemand: yes
    sourceOnDemandStartTimeout: 10s
    sourceOnDemandCloseAfter: 10s
  cam-3:
    source: rtsp://192.168.68.93:8554/live
    rtspTransport: tcp
    sourceOnDemand: yes
    sourceOnDemandStartTimeout: 10s
    sourceOnDemandCloseAfter: 10s
  cam-4:
    source: rtsp://192.168.68.94:8554/live
    rtspTransport: tcp
    sourceOnDemand: yes
    sourceOnDemandStartTimeout: 10s
    sourceOnDemandCloseAfter: 10s
EOF

# Conferir que o YAML é válido
mediamtx /etc/mediamtx/mediamtx.yml &
sleep 2
# Se subiu sem erro, vai ver "[RTSP] / [HLS] listener opened on..."
# Pare com Ctrl+C ou:
pkill mediamtx
```

`sourceOnDemand: yes` significa: mediamtx só conecta na câmera quando alguém pede o stream — economiza banda da câmera quando ninguém está vendo.

---

## Passo 7 — Criar systemd unit pra mediamtx rodar como serviço

Em produção mediamtx tem que subir no boot e reiniciar sozinho se travar. Systemd resolve.

```bash
# Criar usuário do sistema (sem login, só pra rodar o daemon)
sudo useradd -r -s /usr/sbin/nologin mediamtx 2>/dev/null || echo "(usuário mediamtx já existe)"

# Permissões na config
sudo chown -R mediamtx:mediamtx /etc/mediamtx

# Criar unit
sudo tee /etc/systemd/system/mediamtx.service > /dev/null <<'EOF'
[Unit]
Description=Aerobi mediamtx (RTSP → HLS fan-out)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=mediamtx
Group=mediamtx
ExecStart=/usr/local/bin/mediamtx /etc/mediamtx/mediamtx.yml
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

# Hardening básico
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
ReadWritePaths=/var/log

[Install]
WantedBy=multi-user.target
EOF

# Habilitar e iniciar
sudo systemctl daemon-reload
sudo systemctl enable mediamtx
sudo systemctl start mediamtx

# Validar
sudo systemctl status mediamtx --no-pager
# Esperado: active (running)
```

---

## Passo 8 — Validar HLS servindo

Agora o teste end-to-end: pedir o playlist HLS de uma câmera. O `sourceOnDemand` faz com que mediamtx só conecte na câmera no momento do request — então a primeira chamada pode demorar 2-3s.

> **Atenção ao redirect**: mediamtx adiciona um cookie de proteção contra hotlinking, então a primeira chamada retorna `HTTP 302 → ?cookieCheck=1`. Use `curl -L` (segue redirect) ou um player de vídeo (já segue automaticamente).

```bash
# Pedir o manifest HLS da cam-1 (-L pra seguir o redirect cookieCheck)
curl -iL http://localhost:8888/cam-1/index.m3u8
# Esperado: HTTP 302 → HTTP 200 com Content-Type: application/vnd.apple.mpegurl
# Corpo: #EXTM3U / #EXT-X-VERSION:9 / lista de variant streams

# Repetir pras 4 câmeras
for cam in cam-1 cam-2 cam-3 cam-4; do
    code=$(curl -sL -o /tmp/m3u8 -w "%{http_code}" http://localhost:8888/$cam/index.m3u8)
    if [ "$code" = "200" ]; then
        echo "  $cam — HTTP 200 — $(wc -l < /tmp/m3u8) linhas no playlist"
    else
        echo "  $cam — HTTP $code — FAIL"
    fi
done
```

Se as 4 retornarem HTTP 200 com playlists válidas, parabéns: o pipeline `câmera fake → mediamtx → HLS` está fechado, **idêntico** ao que vai rolar em produção (só trocando câmera fake pela Intelbras real).

Se as 4 retornaram `HTTP 200`, o pipeline está fechado: `câmera fake → RTSP → mediamtx → HLS`. É exatamente o que vai acontecer no Raspi real, só trocando câmera fake por Intelbras.

---

## Passo 9 — Validar do host (do laptop)

Sair do raspi-sim:

```bash
exit
```

De volta no seu laptop, **a porta 8888 do raspi-sim NÃO está exposta no host** (só a 2222 do SSH está). Em produção, isso seria acessado via tailnet (porta 8888 no IP `100.64.0.9`). No lab, pra testar do laptop, você pode:

**Opção 1**: tunelar via SSH (1 cmd, sem mexer no compose):

```bash
# Em outro terminal — abre tunnel local 8888 → raspi-sim:8888
ssh -i dev/aerodrome-lab/ssh/id_ed25519 -p 2222 \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -L 8888:localhost:8888 -N \
    deploy@localhost

# Em outro terminal — testar
curl -i http://localhost:8888/cam-1/index.m3u8
```

**Opção 2**: abrir num player de vídeo:

```bash
# Com VLC
vlc http://localhost:8888/cam-1/index.m3u8

# Com ffplay
ffplay http://localhost:8888/cam-1/index.m3u8

# Com mpv
mpv http://localhost:8888/cam-1/index.m3u8
```

Você verá os color bars do `testsrc2` (timestamp + frame counter) — exatamente o que veria pra uma câmera real, só com conteúdo sintético.

---

## Comparação manual ↔ Ansible

Cada passo deste guia vira uma task na role correspondente:

| Passo manual | Equivalente Ansible | Issue |
|---|---|---|
| 1 — apt update + utilitários | role `common` (já existe) | — |
| 3 — IP forwarding sysctl | role `aerodrome_edge` task | #9 |
| 4 — Tailscale up + advertise-routes | role `aerodrome_edge` task | #9 |
| 5 — baixar e instalar mediamtx | role `mediamtx` task | #8 |
| 6 — config mediamtx.yml | role `mediamtx` template | #8 |
| 7 — systemd unit + enable | role `mediamtx` task + handler | #8 |
| 8 — validação HLS | task de smoke test | #8 |

Quando as roles existirem, o equivalente automatizado disso tudo é:

```bash
ansible-playbook -i inventory/dev-aerodrome playbooks/setup_aerodrome.yml --skip-tags tailscale
# (ou em produção, sem o --skip-tags)
```

E a aplicação vira idempotente — re-rodar não muda nada.

---

## Reset

Quando quiser começar do zero:

```bash
# Do laptop:
cd dev/aerodrome-lab
make clean         # apaga containers + chaves SSH
make up            # sobe lab limpo
make ssh           # entra no raspi-sim "virgem"
```

---

## Próximos passos sugeridos

Depois de seguir esse guia até o fim com sucesso, dá pra:

1. **Quebrar de propósito** e debugar — desliga uma câmera (`docker stop aerobi-lab-cam-1`), pede o m3u8, observa erro
2. **Repetir tudo num Raspberry Pi físico** — mesmos comandos (com Tailscale dessa vez)
3. **Implementar a role mediamtx (issue #8)** — copiando os blocos `sudo tee`/`useradd`/`systemctl` deste guia pra tasks Ansible
