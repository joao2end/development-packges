# Ambiente de Desenvolvimento

Instalador grafico para Windows que prepara uma maquina de desenvolvimento do zero: voce marca o que quer, clica em **Instalar** e acompanha o progresso. O build gera **um unico executavel**, `dist\Instalar-Ambiente.exe`, que ja leva dentro todos os icones e o pacote do Gerenciador de Chaves SSH.

## O que o instalador faz

- Interface moderna (WPF, tema escuro, janela sem moldura) com um cartao por programa, agrupados por categoria.
- Selecao por clique, com **Marcar todos** e **Desmarcar**.
- Progresso por programa (Na fila, Instalando, Concluido, Falhou, Cancelado), barra de progresso geral e log em tempo real.
- Botao **Parar** para cancelar no meio da instalacao.
- Resolve dependencias sozinho: marcar o Flutter marca Git, JDK e Android SDK; marcar o React Native marca Node, JDK e Android SDK; e assim por diante.
- Pede permissao de administrador (UAC) ao abrir.

## Programas disponiveis

| Grupo | Itens |
|---|---|
| Ferramentas base | NVM for Windows, Node.js (ultima versao via NVM), Python 3.13, Git, Docker Desktop, GitHub CLI, AWS CLI |
| Mobile | JDK 17 (Temurin), Android Studio, Android SDK, Flutter SDK, React Native |
| Editores e IA | Visual Studio Code, Cursor, Claude Code (instalador oficial), Graft |
| Comunicacao e produtividade | Slack, Obsidian |
| Rede e acesso | Gerenciador de Chaves SSH, Pritunl Client |
| Bancos de dados | PostgreSQL (v18, com fallback para v17), MongoDB Server |
| Gerenciadores de banco | DBeaver Community, MongoDB Compass, pgAdmin 4 |

A maior parte e instalada com `winget`. As excecoes:

- **Node.js**: `nvm install latest` e `nvm use latest`.
- **Claude Code**: instalador oficial (`irm https://claude.ai/install.ps1 | iex`).
- **Graft**: `npm install -g @nanonets/graft`.
- **PostgreSQL**: pede a senha do superusuario `postgres` na janela (sem espacos ou aspas).
- **JDK 17**: apos instalar, grava `JAVA_HOME` e adiciona `bin` ao PATH do usuario.
- **Android SDK**: baixa as command-line tools de `dl.google.com`, aceita as licencas e instala `platform-tools`, as APIs 35 e 36 e o `build-tools` 35 e 36. Grava `ANDROID_HOME`, `ANDROID_SDK_ROOT` e adiciona `platform-tools` e `cmdline-tools\latest\bin` ao PATH.
- **Flutter SDK**: clona o canal `stable` em `C:\src\flutter`, adiciona `bin` ao PATH, aponta o SDK do Android e roda `flutter doctor`.
- **React Native**: nao instala nada proprio; garante Node, JDK 17 e Android SDK. Crie projetos com `npx @react-native-community/cli init MeuApp`.

Variaveis de ambiente sao gravadas no escopo do **usuario**. Abra um terminal novo depois da instalacao para o PATH atualizar (o Docker pode pedir reinicio).

## Gerenciador de Chaves SSH

Pacote proprio do projeto (`pacotes\gerenciador-ssh`): gerencia varias contas Git (GitHub, Bitbucket, GitLab...) ao mesmo tempo, com uma chave ed25519 e um bloco `Host` no `~/.ssh/config` por conta, identidade git por pasta e instalacao do GitHub CLI. Usa as fontes Open Sans e Fira Code.

O `.exe` embute o pacote (zip em base64). Ao marcar o item, o instalador extrai em `%LOCALAPPDATA%\Programs\GerenciadorSSH` e cria o atalho **Gerenciador de Chaves SSH** no Menu Iniciar. Nao existe um segundo executavel.

## Estrutura do projeto

| Caminho | Conteudo |
|---|---|
| `build.ps1` | Unico ponto de entrada: gera `dist\Instalar-Ambiente.exe` |
| `src\instalador.ps1` | Codigo do instalador: interface, catalogo de programas e logica de instalacao |
| `pacotes\gerenciador-ssh\` | Pacote proprio: `gerenciador-ssh.ps1` e `fontes\` |
| `assets\icones\` | Icones PNG dos programas (embutidos no `.exe`) |
| `dist\` | Saida do build (somente o `.exe`; ignorada pelo git) |
| `build\` | Temporaria, criada e apagada pelo build (ignorada pelo git) |

## Build

Requisitos: Windows 10/11 com winget (App Installer) e PowerShell 5.1. O modulo `ps2exe` e instalado automaticamente para o usuario.

```powershell
powershell -ExecutionPolicy Bypass -File .\build.ps1
```

O build desenha os icones (instalador e Gerenciador SSH), compacta o pacote SSH, junta tudo ao `src\instalador.ps1` e compila com `ps2exe` (administrador, sem console, STA). No fim confere que o projeto tem somente um `.exe`. Feche o instalador antes de gerar de novo, porque o arquivo fica bloqueado enquanto esta aberto.

## Desenvolvimento

`src\instalador.ps1` roda direto, lendo os icones de `assets\icones` e o pacote SSH de `pacotes\gerenciador-ssh`:

```powershell
powershell -ExecutionPolicy Bypass -STA -File .\src\instalador.ps1
```

Para adicionar um programa, inclua uma linha no `$catalogo` de `src\instalador.ps1` (campos `Grupo`, `Nome`, `Desc`, `Icone`, `Tipo` e `Id`; opcionalmente `Chave` e `Deps`) e um PNG com o nome do `Icone` em `assets\icones`. Para programas instalaveis pelo winget, use `Tipo = 'winget'` e o ID do pacote (`winget search <nome>`).

## Observacoes

- Os icones sao favicons baixados dos sites oficiais; alguns tem so 32 a 48 px.
- Executaveis feitos com `ps2exe` podem ser marcados como suspeitos pelo Windows Defender ou SmartScreen (falso positivo comum).
