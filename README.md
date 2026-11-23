# bridge-tor-setup

Um script (`setup.sh`) que prepara uma VPS Debian do zero e sobe uma bridge Tor obfs4 com monitoramento: hardening básico, Docker, a bridge oficial do Tor Project, Uptime Kuma e um resumo diário no Telegram.

Uma bridge ajuda quem está em países que bloqueiam o Tor a se conectar. Diferente de um relé, ela não aparece na lista pública da rede.

## O que ele faz

1. Atualiza o sistema e instala pacotes essenciais
2. Configura firewall (UFW), fail2ban, hardening de kernel, atualizações automáticas de segurança, sincronismo de horário e swap
3. Instala Docker e aplica a correção **ufw-docker** (sem isso, o Docker ignora as regras do UFW)
4. Clona o repositório oficial da bridge (Tor Project) e gera o `docker-compose.yml` com os três serviços
5. Na primeira execução, gera um `.env` com placeholders e **para**, esperando você preencher
6. Na segunda execução, sobe a stack e tenta capturar o fingerprint da bridge automaticamente

## Como usar

```bash
# 1ª execução — gera o .env
bash setup.sh

# edite o .env com seus dados reais (ver campos abaixo)
nano /opt/tor-bridge-stack/.env

# 2ª execução — sobe a stack de fato
bash setup.sh
```

Pode rodar de novo quantas vezes precisar — os passos já concluídos são pulados (clone do repo, criação do swap, etc.).

## Campos do `.env`

| Campo | O que é | Observação |
|---|---|---|
| `OR_PORT` / `PT_PORT` | Portas da bridge | Padrão 9001/9002, só mude se já usar essas portas |
| `CONTACT_EMAIL` | E-mail de contato da bridge | Não é público como num relé — só quem tem o fingerprint acessa |
| `BRIDGE_NICKNAME` | Nome da bridge | **Só [a-zA-Z0-9], entre 1 e 19 caracteres** — sem isso a bridge não inicia |
| `TELEGRAM_BOT_TOKEN` | Token do bot (via @BotFather) | Regenere se ele já foi exposto em algum lugar |
| `TELEGRAM_CHAT_ID` | Seu chat ID | Pegue em `api.telegram.org/bot<TOKEN>/getUpdates` depois de mandar `/start` pro bot |
| `BRIDGE_FINGERPRINT` | Hash da identidade da bridge | Deixe vazio — o script preenche sozinho após o primeiro start |
| `CRON_SCHEDULE` | Horário do resumo diário | **Tem que ficar entre aspas**, ex: `"0 9 * * *"` — sem aspas quebra o script |

## Se o fingerprint não for capturado automaticamente

```bash
cd /opt/tor-bridge-stack
docker compose logs tor-bridge | grep -i "hashed identity"
# cole o valor em BRIDGE_FINGERPRINT no .env, depois:
docker compose up -d --build daily-summary
```

## O que fica manual (fora do script)

O **Uptime Kuma** não é configurável por arquivo — só pela interface web dele:

1. Túnel SSH: `ssh -L 3001:localhost:3001 root@<ip-da-vps>`
2. Abrir `http://localhost:3001`, criar conta admin
3. **Settings → Notifications** → adicionar Telegram (mesmo token/chat ID do `.env`)
4. **Add New Monitor** → tipo `TCP Port` → porta = valor de `OR_PORT` → marcar a notificação criada

## Erros conhecidos

- `.env: line X: 9: command not found` → falta aspas em `CRON_SCHEDULE`. Corrija para `CRON_SCHEDULE="0 9 * * *"`.
- Bridge não inicia / erro de "Nickname" → `BRIDGE_NICKNAME` tem caractere inválido (hífen, underscore, espaço, acento) ou mais de 19 caracteres.

## Licença

[MIT](LICENSE)
