<p align="right"><b>macOS</b> · <a href="https://github.com/tw93/Mole/tree/windows#readme">Windows</a> · <a href="https://github.com/tw93/Mole/tree/linux#readme">Linux</a></p>

<div align="center">
  <h1>Mole</h1>
  <p><b>Limpeza profunda, desinstalação, otimização, análise de disco e monitoramento do seu Mac. CLI gratuita e open source, além de um app para Mac.</b></p>
  <p><a href="README.md">English</a> · <a href="README_CN.md">中文</a> · <a href="README_TW.md">繁體</a> · <a href="README_JA.md">日本語</a> · <a href="README_KR.md">한국어</a> · <a href="README_DE.md">Deutsch</a> · <a href="README_FR.md">Français</a> · <a href="README_PL.md">Polski</a> · Português · <a href="README_UA.md">Українська</a> · <a href="README_RU.md">Русский</a></p>
  <a href="https://github.com/tw93/mole/stargazers"><img src="https://img.shields.io/github/stars/tw93/mole?style=flat-square" alt="Stars"></a>
  <a href="https://github.com/tw93/mole/releases"><img src="https://img.shields.io/github/v/release/tw93/mole?label=version&style=flat-square" alt="Version"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-GPL_v3-blue.svg?style=flat-square" alt="License"></a>
  <a href="https://github.com/tw93/mole/commits"><img src="https://img.shields.io/github/commit-activity/m/tw93/mole?style=flat-square" alt="Commits"></a>
  <a href="https://x.com/HiTw93"><img src="https://img.shields.io/badge/follow-Tw93-red?style=flat-square&logo=x" alt="Twitter"></a>
  <a href="https://t.me/+9f9gf4ZrFSQ2OWVl"><img src="https://img.shields.io/badge/chat-Telegram-blueviolet?style=flat-square&logo=Telegram" alt="Telegram"></a>
</div>

<p align="center">
  <img src="./docs/img/big-mole.png" alt="Resultados da limpeza do Mole" width="1000" />
</p>

> 💡 Este repositório é a CLI gratuita e open source (`mo`). Prefere um app nativo? O [Mole for Mac](https://mole.fit/) é um download separado, com limpeza revisada antes de apagar, resíduos testados para mais de 900 apps, manutenção, análise detalhada do disco, status em tempo real e controle das ventoinhas em Macs compatíveis. No Windows, o app nativo é o [Mole for Windows](https://mole.fit/windows). `brew install mole` instala apenas a CLI.

## Recursos

- **Kit de ferramentas tudo em um**: reúne fluxos no estilo CleanMyMac, AppCleaner, DaisyDisk e iStat Menus em um único comando de terminal
- **Limpeza profunda**: remove caches, logs, resíduos e dados órfãos de apps para recuperar espaço em disco
- **Desinstalador inteligente**: remove apps junto com LaunchAgents, preferências e resíduos
- **Analisador de disco**: mostra o uso do disco em uma TUI interativa, encontra arquivos grandes e navega pelas pastas
- **Manutenção do sistema**: limpa o cache de DNS, atualiza QuickLook e ícones e otimiza bancos de dados do sistema
- **Monitoramento em tempo real**: mostra CPU, memória, E/S de disco, tráfego de rede e processos em tempo real

## Início rápido

O Mole exige macOS 12 ou mais recente e funciona em Macs Intel e Apple Silicon. Se o Homebrew não oferece mais suporte à sua versão do macOS, use a instalação por script.

**Instalar via Homebrew**

```bash
brew install mole
```

**Ou via script**

```bash
curl -fsSL https://raw.githubusercontent.com/tw93/mole/main/install.sh | bash
```

**Com um agente de IA**

Diga ao seu agente:

> Install Mole for me by reading https://raw.githubusercontent.com/tw93/Mole/main/llms.txt

Ou instale a skill você mesmo. Com ela, Claude Code, Codex, Cursor e outros agentes mostram cada limpeza com `--dry-run` antes de remover qualquer coisa, e deixam a desinstalação de apps e as etapas de administrador com você. Atualize com `npx skills update -g -y`.

```bash
npx skills add tw93/Mole -a claude-code codex cursor -g -y
```

Como plugin do host: `/plugin marketplace add tw93/Mole` e depois `/plugin install mole@mole` no Claude Code, `codex plugin marketplace add tw93/Mole` e depois `codex plugin add mole@mole` no Codex, ou `dsh plugin --profile <name> add dsh-mole` no DeepSeek Harness.

**Executar**

```bash
mo                           # Menu interativo
mo clean                     # Limpeza profunda + resíduos de apps já desinstalados
mo uninstall                 # Remove apps instalados + seus resíduos
mo optimize                  # Atualiza caches e serviços
mo analyze                   # Explorador visual do disco (ou 'mo analyse')
mo status                    # Painel de saúde do sistema em tempo real
mo purge                     # Limpa artefatos de build de projetos
mo installer                 # Encontra e remove arquivos de instalação
mo slim                      # Remove o código Intel de apps universais

mo touchid                   # Configura o Touch ID para o sudo
mo completion                # Configura o autocompletar do shell com Tab
mo update                    # Atualiza o Mole
mo update --nightly          # Atualiza para o build mais recente não lançado da main, só na instalação por script
mo remove                    # Remove o Mole do sistema
mo --help                    # Mostra a ajuda
mo --version                 # Mostra a versão instalada
```

**Pré-visualizar com segurança**

```bash
mo clean --dry-run
mo uninstall --dry-run
mo optimize --dry-run
mo purge --dry-run
mo installer --dry-run
mo slim --dry-run
mo history
mo history --json

mo clean --dry-run --debug   # Pré-visualização + logs detalhados
mo optimize --whitelist      # Gerencia regras de otimização protegidas
mo clean --whitelist         # Gerencia caches protegidos
mo purge --paths             # Configura as pastas de busca de projetos
mo analyze /Volumes          # Analisa apenas discos externos
mo analyze /private/tmp      # Revisa pastas temporárias do usuário
```

<details>
<summary><strong>Outras formas de instalação</strong></summary>

Para instalar uma versão específica, passe qualquer tag da [página de releases](https://github.com/tw93/mole/releases), com ou sem o `V` inicial. Para acompanhar o branch de desenvolvimento, passe `main`:

```bash
curl -fsSL https://raw.githubusercontent.com/tw93/mole/main/install.sh | bash -s -- 1.74.0
curl -fsSL https://raw.githubusercontent.com/tw93/mole/main/install.sh | bash -s -- main
```

`main` instala código ainda não lançado do branch padrão, então espere arestas. `latest` ainda funciona como alias legado de `main`; apesar do nome, não instala a versão estável mais recente.

O script normalmente instala em `/usr/local/bin`, o que pode pedir a senha de administrador. Instale em uma pasta do seu usuário se quiser que as próximas execuções de `mo update` não peçam senha:

```bash
mkdir -p "$HOME/.local/bin"
curl -fsSL https://raw.githubusercontent.com/tw93/mole/main/install.sh | bash -s -- --prefix "$HOME/.local/bin"
export PATH="$HOME/.local/bin:$PATH"
```

Adicione o mesmo export de `PATH` ao `~/.zshrc` ou ao perfil do seu shell para novos terminais. O Mole atualiza a instalação que você executou, então continua usando essa pasta. Comandos que alteram arquivos do sistema ainda podem pedir acesso de administrador.

**Nix**

No macOS, usuários de Nix podem instalar o flake a partir da `main`, que contém mudanças ainda não lançadas:

```bash
nix profile install github:tw93/mole/main#mole
nix profile upgrade mole
nix profile remove mole
```

Para uma instalação declarativa, adicione `github:tw93/mole/main` como input do flake e use o pacote `packages.${system}.mole`. Atualize ou remova o Mole pelo Nix; `mo update` e `mo remove` não mexem em instalações gerenciadas pelo Nix.

</details>

**No Windows** ([Windows CLI](https://github.com/tw93/Mole/tree/windows#readme))

```powershell
iwr -useb https://raw.githubusercontent.com/tw93/Mole/windows/quick-install.ps1 | iex
```

**No Linux** ([Linux CLI](https://github.com/tw93/Mole/tree/linux#readme))

```bash
curl -fsSL https://raw.githubusercontent.com/tw93/Mole/linux/install.sh | bash
```

O Mole é distribuído apenas pelo Homebrew, por este repositório e pelo [mole.fit](https://mole.fit/). `molemac.com`, `moleapp.net` e `molefit.com` não são o Mole, e o app para Windows em `mole.bluecatbot.com` é um projeto separado da comunidade.

## Segurança

O Mole pode remover arquivos, por isso valida caminhos, protege locais compartilhados e do sistema e pede confirmação quando uma ação precisa disso. Quando não consegue provar que um item é seguro de alterar, o Mole o pula ou recusa.

- `clean`, `uninstall`, `purge`, `installer`, `slim` e `remove` podem apagar arquivos, então revise-os primeiro com `--dry-run` e adicione `--debug` quando necessário
- Execute o Mole sem `sudo`; ele pede acesso de administrador só quando precisa
- `mo uninstall`, `mo analyze` e `mo slim` mandam o que for apagado para o Lixo por padrão, após confirmação; `clean`, `purge` e `installer` apagam permanentemente. `mo uninstall --permanent` não usa o Lixo
- A atividade de limpeza é registrada em `~/Library/Logs/mole/operations.log`; revise com `mo history` ou desative com `MO_NO_OPLOG=1`
- Proteja caches com `mo clean --whitelist`, ou itens de manutenção com `mo optimize --whitelist`
- Se o arquivo de whitelist não puder ser lido, `clean`, `purge` e `optimize` param em vez de rodar sem ele

Leia [SECURITY.md](SECURITY.md) e [SECURITY_AUDIT.md](SECURITY_AUDIT.md) para orientações de reporte, limites de segurança e limitações atuais.

## Configuração

O Mole funciona sem configuração. Estas variáveis de ambiente o adaptam a discos lentos, rede travada ou montagens em nuvem; aumente um timeout só quando o Mole informar que uma etapa excedeu o tempo.

- `MOLE_TIMEOUT_QUICK_DETECT_SEC` (2): verificações de disponibilidade de comandos
- `MOLE_TIMEOUT_SHORT_QUERY_SEC` (3): consultas leves, como `df` e `tmutil status`
- `MOLE_TIMEOUT_MEDIUM_PROBE_SEC` (5): verificações que percorrem uma árvore de pastas ou acessam a rede
- `MOLE_TIMEOUT_PKG_LIST_SEC` (10): listagens de gerenciadores de pacotes, como `brew list`
- `MOLE_TIMEOUT_PKG_CLEANUP_SEC` (20): limpezas de cache que percorrem o disco
- `MOLE_TIMEOUT_DISK_VERIFY_SEC` (30): verificação e reparo do sistema de arquivos
- `MOLE_TIMEOUT_HINT_SCAN_SEC` (15): buscas sem limite em pastas do usuário
- `MOLE_CLOUD_OFFICE_SECTION_BUDGET_SEC` (300): tempo total da seção de limpeza de nuvem e Office

O número entre parênteses é o padrão em segundos. Por exemplo, para dar mais tempo às buscas em um disco lento:

```bash
MOLE_TIMEOUT_HINT_SCAN_SEC=60 MOLE_TIMEOUT_MEDIUM_PROBE_SEC=15 mo clean
```

## Recursos em detalhe

Os exemplos abaixo são resumidos. Os itens disponíveis, os tamanhos e os motivos para pular dependem do seu Mac.

### Limpeza (Clean)

`mo clean` revisa caches, logs, arquivos temporários, artefatos de desenvolvimento e resíduos de apps que não estão mais instalados, todos conhecidos como seguros. Por padrão, esvazia o `~/.Trash`; para mantê-lo, selecione Trash em `mo clean --whitelist`, o mesmo menu que protege os caches que você quer manter. O Lixo de volumes, como `/Volumes/*/.Trashes`, não é esvaziado junto. As seleções ficam salvas em `~/.config/mole/whitelist`. Antes de adicionar caminhos próprios, abra o menu e pressione Enter para salvar as seleções, depois acrescente um caminho por linha. Um arquivo existente substitui os padrões opcionais; as proteções de segurança embutidas continuam valendo.

```text
$ mo clean

Clean Your Mac

⚙ Apple Silicon | Free space: 219.0GB

➤ User essentials
  ✓ User app cache · 18 items, 2.4GB
  ✓ User app logs · 7 items, 12.8MB
  ✓ Trash · emptied, 9 items

➤ App caches
  ✓ App Store cache · 8 items, 248.5MB

➤ Browsers
  ✓ Safari cache · 24 items, 642.1MB
  ✓ Chrome cache · 31 items, 1.2GB

➤ Developer tools
  ✓ npm cache · cleaned
  ◎ pnpm cache · skipped (pnpm busy)

======================================================================
Cleanup complete
Removed: 4.5GB · 97 items
Free space: 223.5GB (+4.5GB)
======================================================================
```

### Desinstalação (Uninstall)

`mo uninstall` remove um app instalado junto com os arquivos relacionados que o Mole consegue associar a ele. Dados compartilhados são mantidos quando outra cópia instalada ainda os usa. Se o app já foi removido, use `mo clean` para procurar resíduos.

Dados pessoais, incluindo ajustes e plugins, são mantidos por padrão. Pressione `D` na pré-visualização da remoção para selecionar caminhos de dados individuais. `mo uninstall --with-data` começa com esses dados selecionados, exceto perfis de navegador e contêineres de App Group; a pré-visualização os lista separadamente e `D` ainda permite manter qualquer caminho. Depois da remoção, referências em configurações de shell, Hook ou MCP são listadas apenas por arquivo e linha; o Mole não edita essas configurações.

```text
$ mo uninstall

Select Apps to Remove  1/3 selected

➤ ● Photoshop 2024                4.20GB | 2mo ago
  ○ IntelliJ IDEA                 2.80GB | 3d ago
  ○ Premiere Pro                  3.40GB | 2w ago

Files to be removed:

✓ Photoshop 2024, 4.20GB
  ✓ /Applications/Adobe Photoshop 2024/Adobe Photoshop 2024.app

Personal data kept:
  ~/Library/Application Support/Adobe/Adobe Photoshop 2024
  ~/Library/Preferences/com.adobe.Photoshop.plist

D choose personal data

======================================================================
Uninstall complete
Removed 1 app · 4.20GB: Photoshop 2024
======================================================================
```

### Otimização (Optimize)

`mo optimize` executa uma manutenção limitada dos serviços compatíveis do Finder, de rede, de bancos de dados e do macOS. Tarefas desnecessárias, inseguras no momento ou indisponíveis são puladas com um motivo. Use `mo optimize --whitelist` para excluir tarefas ou padrões de caminho, como uma imagem de disco montada há muito tempo em `/Volumes/mail` que não deve aparecer como candidata a desmontar.

```text
$ mo optimize

Optimize

⚙ System  18/32 GB RAM | 616/926 GB Disk | Uptime 6d

PERFORMANCE DIAGNOSIS
  ✓ No sustained high-CPU bottleneck detected

➤ Finder Cache Refresh
  ✓ QuickLook thumbnails refreshed
  ✓ Icon services cache rebuilt

➤ Network Cache Refresh
  ✓ DNS cache refreshed

➤ Database Optimization
  ◎ Close these apps before database optimization: Safari

➤ Disk Health
  ✓ Disk verify skipped

======================================================================
Optimization Complete
Applied 2 optimizations
13 unchanged | 3 skipped | 1 unavailable
======================================================================
```

### Análise de disco (Analyze)

`mo analyze` abre um explorador de disco no terminal. Ele aceita setas e navegação estilo Vim, filtros, seleção múltipla, pré-visualização no Finder e envio confirmado para o Lixo. Discos externos ficam fora da visão geral padrão; inspecione-os com `mo analyze /Volumes` ou com um ponto de montagem específico. Use `mo analyze /private/tmp` para revisar arquivos temporários do usuário sem transformá-los em alvos de limpeza automática. Buscas arquivo por arquivo contam uma única vez os clones APFS que compartilham todos os blocos; estimativas rápidas de pastas ainda podem contar blocos compartilhados mais de uma vez.

Um tamanho terminado em `+` contém os bytes medidos em uma busca parcial; `unknown` significa que o tamanho não pôde ser medido. Resultados interrompidos por falhas temporárias, como timeouts, não substituem medições completas em cache, e uma atualização posterior pode recuperar os dados que faltam. Pastas que o macOS não deixa o terminal ler continuam parciais até o acesso mudar. A lista no terminal mantém as 30 maiores entradas, então uma entrada ilegível pode ficar fora dela; o total ainda indica uma busca parcial. A saída JSON de uma pasta inclui todas as entradas analisadas.

`mo analyze --json /path` inclui `scan_status` no resultado e em cada entrada: `complete`, `partial` ou `unavailable`. Os tamanhos numéricos contêm bytes medidos; um zero com `unavailable` não significa pasta vazia. Buscas parciais ainda terminam com sucesso, então a automação deve verificar `scan_status`. A completude vale dentro das exclusões de busca que o Mole já aplica e não promete um snapshot atômico do sistema de arquivos.

```text
$ mo analyze

Analyze Disk  (302.1GB free)
Select a location to explore:

 ▶  1. ████████████████████████  47.9%  |  Home                       75.4GB
    2. ███████████               22.0%  |  User Library               34.6GB
    3. ███████                   14.2%  |  Applications               22.4GB
    4. █████                     10.7%  |  System Library             16.9GB
    5. ███                        5.2%  |  Old Downloads (90d+)       8.2GB  >3mo
```

### Status do sistema (Status)

`mo status` é um painel somente leitura de hardware, pressão do sistema, atividade do disco, tráfego de rede, energia e processos.

Quando a rota padrão IPv4 passa por um túnel, os gráficos de rede usam as taxas dessa interface para não contar o mesmo tráfego de novo na interface física. O JSON mantém as taxas por interface, incluindo o túnel roteado; túneis ociosos que não são o padrão ficam ocultos.

```text
$ mo status

Mole Status  Health ● 92  MacBook Pro · M4 Pro · 32GB · macOS 26

⚙ CPU                                    ▦ Memory
Total   ████████████░░░░░░░  45.2%       Used    ███████████░░░░░░░  58.4%
Load    0.82 / 1.05 / 1.23 (8 cores)     Total   18.7 / 32.0 GB
Core 1  ███████████████░░░░  78.3%       Free    ████████░░░░░░░░░░  41.6%
Core 2  ████████████░░░░░░░  62.1%       Avail   13.3 GB

▤ Disk                                   ⚡ Power
Used    █████████████░░░░░░  67.2%       Level   ██████████████████  100%
Free    156.3 GB                         Status  Charged
Read    ▮▯▯▯▯  2.1 MB/s                  Health  Normal · 423 cycles
Write   ▮▮▮▯▯  18.3 MB/s                 Temp    58°C · 1200 RPM

⇅ Network                                ▶ Processes
Down    ▁▁█▂▁▁▁▁▁▁▁▁▇▆▅▂  0.54 MB/s      Zombies 3 · Chrome (4242) ×3
Up      ▄▄▄▃▃▃▄▆▆▇█▁▁▁▁▁  0.02 MB/s      Code       ▮▮▮▮▯  42.1%
Proxy   HTTP · 192.168.1.100             Chrome     ▮▮▮▯▯  28.3%
```

A nota de saúde combina CPU, memória, capacidade do disco, status SMART, E/S, temperatura, estado da bateria e tempo ligado, com faixas coloridas. Pressione `k` para mostrar ou esconder o gato, `c` para alternar o número de núcleos de CPU exibidos ou `q` para sair; as preferências de exibição são salvas.

<details>
<summary><strong>JSON, NDJSON e alertas de processos</strong></summary>

- `mo analyze --json ~/Documents` retorna um relatório do disco em JSON, uma única vez
- `mo status --json` retorna um snapshot do status em JSON, uma única vez
- `mo status | jq '.health_score'` muda para JSON automaticamente quando a saída é redirecionada por pipe
- `mo status --watch --interval 2s` transmite JSON delimitado por linha a partir de um coletor já aquecido
- `mo history --json` retorna a atividade de limpeza em JSON. As sessões incluem `run_id` (uma string opaca, vazia quando nenhuma identidade foi registrada) e `attribution`: `run` para execuções identificadas, `command` para o agrupamento legado por comando, ou `ambiguous` quando os marcadores legados não conseguem distinguir uma interrupção de execuções sobrepostas. As ações registradas continuam disponíveis; contagens ambíguas não podem ser atribuídas com confiança a execuções individuais. Um `ended_at` vazio significa que nenhum marcador de fim foi registrado
- `mo uninstall --list` retorna os apps instalados em JSON com `name`, `bundle_id`, `source`, `uninstall_name`, `path` e `size`

```text
$ mo analyze --json ~/Documents
{
  "path": "/Users/you/Documents",
  "overview": false,
  "entries": [
    { "name": "Library", "path": "...", "size": 80939438080, "is_dir": true }
  ],
  "large_files": [
    { "name": "backup.zip", "path": "...", "size": 8796093022 }
  ],
  "total_size": 168393441280,
  "total_files": 42187
}

$ mo status --json
{
  "host": "MacBook-Pro",
  "health_score": 92,
  "cpu": { "usage": 45.2, "logical_cpu": 8 },
  "memory": { "total": 34359738368, "used": 20078972109, "used_percent": 58.4 },
  "disks": [],
  "process_collected_at": "2026-08-29T12:30:00Z",
  "process_stale": false,
  "zombie_count": 3,
  "zombie_parents": [
    { "pid": 4242, "name": "Google Chrome for Testing", "count": 3 }
  ],
  "zombie_parents_complete": true,
  "uptime": "3d 12h 45m"
}
```

O diagnóstico de processos zumbis é somente leitura e não afeta a nota de saúde nem encerra processos. Antes
de o Mole ter uma amostra de processos bem-sucedida, `process_collected_at`, `process_stale`, `zombie_count` e
`zombie_parents_complete` são omitidos e `zombie_parents` é `null`. Snapshots posteriores em modo fast/watch
reaproveitam a última amostra bem-sucedida com o `process_collected_at` original e definem
`process_stale: true`; uma amostra de processos ao vivo o define como `false`. Uma contagem `0` significa que o Mole mediu
e não encontrou zumbis. Os resumos de processos pais contêm no máximo três donos conhecidos;
`zombie_parents_complete: false` significa que a atribuição ficou indisponível, incompleta ou truncada.

Se um coletor falhar, `mo status --json` ainda imprime as métricas coletadas, informa a
falha no stderr e termina com sucesso, do mesmo jeito que `--watch` continua transmitindo. Ele termina com código 1
quando nenhuma métrica de CPU, memória, disco ou processos está disponível, ou quando a saída JSON falha.

O Status também oferece alertas somente leitura para processos que ficam acima de um limite de CPU. Use `--proc-cpu-threshold`, `--proc-cpu-window` ou `--proc-cpu-alerts=false` para ajustá-los ou desativá-los.

</details>

### Limpeza de projetos (Purge)

`mo purge` encontra artefatos de projetos que podem ser reconstruídos, como `node_modules`, `target`, `.build`, `build` e `dist`. Ele agrupa os artefatos por projeto e apaga permanentemente apenas os itens que você confirmar. Artefatos com atividade de arquivos nos últimos 7 dias, ou com atividade que o Mole não consegue verificar, ficam desmarcados por padrão. O Mole usa o `fd` quando disponível e recorre ao `find` caso contrário, e protege pastas que contêm arquivos de par de chaves de deploy, repositórios Git aninhados ou arquivos rastreados pelo Git. Execuções não interativas exigem `mo purge --yes`; use `mo purge --dry-run` para revisar os candidatos antes.

Use Page Up/Down ou `h`/`l` para mudar de página, `[`/`]` para pular entre projetos e `X` para ignorar um projeto e avançar. `/` busca nos caminhos dos projetos e nos nomes dos artefatos, `n` encontra a próxima ocorrência sem mudar as seleções e Enter abre a revisão final dos caminhos. O espaço informado é uma estimativa; artefatos não medidos e buscas incompletas são identificados explicitamente.

<details>
<summary><strong>Exemplo de saída do Purge</strong></summary>

```text
$ mo purge

Purge Project Artifacts

Select Artifacts to Purge
6.00GB, 2 selected

➤ ● ┌ ~/Projects/website        3.80GB | node_modules | 28d
  ○ └ ~/Projects/website         186MB | dist         | <1d
  ● ┌ ~/Projects/rust-app       2.20GB | target       | 2mo
  ○ └ ~/Projects/rust-app         22MB | dist         | <7d

======================================================================
Purge complete
Estimated space freed: 6.00GB | Items: 2 | Free: 223.5GB
======================================================================
```

</details>

<details>
<summary><strong>Caminhos de busca personalizados</strong></summary>

Execute `mo purge --paths` para configurar as pastas de busca, ou edite `~/.config/mole/purge_paths` diretamente:

```shell
~/Documents/MyProjects
~/Work/ClientA
~/Work/ClientB
```

Quando há caminhos personalizados configurados, o Mole busca apenas nessas pastas. Caso contrário, usa padrões como `~/Projects`, `~/GitHub`, `~/dev` e os contêineres de worktrees de agentes compatíveis. A descoberta não salva um resultado incompleto. A busca por artefatos vai até seis níveis abaixo de cada raiz configurada; adicione uma raiz mais próxima para projetos mais profundos. O Purge remove artefatos reconstruíveis dentro de worktrees, nunca os próprios worktrees.

</details>

### Instaladores (Installer)

`mo installer` encontra arquivos DMG, PKG, MPKG, ISO, XIP e ZIP de instalação em Downloads, Mesa, caches do Homebrew, iCloud, Mail, Telegram e outros locais compatíveis, e mostra o tamanho e a origem de cada item antes da remoção. A descoberta tem um limite de tempo acumulado: se uma busca ou leitura de metadados falhar ou exceder o tempo, o Mole descarta a lista e sai sem selecionar arquivos. Arquivos ZIP corrompidos ou ilegíveis são pulados, raízes de busca que são links simbólicos são aceitas, mas links simbólicos dentro delas não são seguidos, e os arquivos selecionados são conferidos de novo com a identidade confirmada no momento da exclusão.

<details>
<summary><strong>Exemplo de saída do Installer</strong></summary>

```text
$ mo installer

Select Installers to Remove, 3.83GB, 5 selected

➤ ● Photoshop_2024.dmg          1.20GB | Downloads
  ● IntelliJ_IDEA.dmg          850.6MB | Downloads
  ● Illustrator_Setup.pkg      920.4MB | Downloads
  ● PyCharm_Pro.dmg            640.5MB | Homebrew
  ● Acrobat_Reader.dmg         220.4MB | Downloads
  ○ AppCode_Legacy.zip         410.6MB | Downloads

======================================================================
Installers cleaned
Removed 5 installers, freed 3.83GB
======================================================================
```

</details>

### Emagrecer apps (Slim)

`mo slim` remove o código Intel que apps universais carregam em Macs com Apple Silicon. Ele lista os apps seus assinados com um Developer ID, com o tamanho do código Intel de cada um, e altera apenas os apps que você selecionar. Cada app é reduzido em uma cópia, mexendo só nos executáveis principais e no código aninhado que tem assinatura própria; a cópia só substitui o app depois de manter o código Apple Silicon e passar nas verificações de assinatura de código e do Gatekeeper, e o original vai para o Lixo. Apps da App Store, apps da Apple, apps configurados para abrir com o Rosetta, apps de outro usuário e apps em execução não são alterados. Não precisa de ferramentas de desenvolvimento, e uma atualização do app traz o código Intel de volta.

## Atalhos rápidos

<details>
<summary><strong>Configuração do Raycast e do Alfred</strong></summary>

Instale cinco atalhos para Clean, Uninstall, Optimize, Analyze e Status:

```bash
curl -fsSL https://raw.githubusercontent.com/tw93/Mole/main/scripts/setup-quick-launchers.sh | bash
```

O script adiciona comandos ao Raycast e, quando as preferências do Alfred estão presentes, workflows correspondentes no Alfred com as palavras-chave `clean`, `uninstall`, `optimize`, `analyze` e `status`.

O Raycast precisa de uma configuração manual:

1. Abra **Raycast Settings > Extensions > Script Commands**.
2. Adicione `~/Library/Application Support/Raycast/script-commands` como pasta de scripts.
3. Execute **Reload Script Directories** no Raycast.

Os atalhos detectam automaticamente Terminal, iTerm2, Alacritty, kitty, WezTerm, Ghostty, Hyper, WindTerm e Warp. Defina `MO_LAUNCHER_APP=<name>` para escolher um; você também pode rodar o Mole direto no [Kaku](https://github.com/tw93/Kaku).

</details>

## Comunidade

Obrigado a todos que ajudaram a construir o Mole. Vá segui-los. ❤️

<a href="https://github.com/tw93/Mole/graphs/contributors">
  <img src="./CONTRIBUTORS.svg?v=2" alt="Contribuidores do Mole" width="1000" />
</a>

<br/><br/>
Feedback real de usuários que compartilharam o Mole no 𝕏.

<img src="./docs/img/mole-love.png" alt="Feedback da comunidade sobre o Mole" width="1000" />

Assista ao [vídeo tutorial do Mole](https://www.youtube.com/watch?v=UEe9-w4CcQ0) do PAPAYA 電腦教室.

## Apoio

- Adquirir o [Mole for Mac](https://mole.fit) é a forma mais direta de apoiar o desenvolvimento do Mole
- Se o Mole ajudou você, dê uma estrela, [compartilhe](https://x.com/intent/tweet?url=https://github.com/tw93/Mole&text=Mole%20-%20Deep%20clean%20and%20optimize%20your%20Mac.) ou abra uma issue ou um PR
- Tenho dois gatos, TangYuan e Coke, e se o Mole deixa sua vida um pouco mais fácil, fique à vontade para pagar uma <a href="https://cats.tw93.fun?name=Mole" target="_blank">ração em lata 🥩</a> para eles

Estas pessoas queridas já fizeram isso 🐱

<a href="https://cats.tw93.fun?name=Mole"><img src="https://raw.githubusercontent.com/tw93/sponsors/main/assets/sponsors.svg" alt="Apoiadores do Mole" width="1000" loading="lazy" /></a>

## Licença

O Mole é open source sob a GPL-3.0; veja [LICENSE](LICENSE). Qualquer versão modificada que você compartilhar deve continuar sob a mesma licença. Se fizer um fork do Mole, use um nome diferente e dê o crédito ao Mole como projeto de origem; veja [TRADEMARK.md](TRADEMARK.md). O [Mole for Mac](https://mole.fit) é um app proprietário separado, e o Mole está aqui para ficar.
