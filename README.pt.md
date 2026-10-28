[🇺🇸 EN](README.md) | [🇵🇱 PL](README.pl.md) | [🇪🇸 ES](README.es.md) | [🇫🇷 FR](README.fr.md) | [🇩🇪 DE](README.de.md) | [🇮🇹 IT](README.it.md) | [🇵🇹 PT](README.pt.md)

---

<p align="center">
  <img src="assets/macos-cleanup-logo.png" alt="macOS Cleanup Logo" width="350" />
</p>

# macOS Cleanup — Limpador de Sistema Profissional

> **Ferramenta de limpeza profissional para macOS** — mais segura do que aplicativos comerciais, totalmente transparente, com controle total do usuário sobre o que é excluído.

<p align="center">
  <img src="https://img.shields.io/badge/build-passing-brightgreen.svg" alt="CI Status" />
  <img src="https://img.shields.io/badge/macOS-10.15%2B-blue.svg" alt="macOS Version" />
  <img src="https://img.shields.io/badge/Bash-3.2%2B-lightgrey.svg" alt="Bash Version" />
  <img src="https://img.shields.io/badge/license-MIT-green.svg" alt="License" />
</p>

## O que é este projeto?

`cleanup_all.sh` é um script bash desenvolvido para usuários avançados de macOS que:

- **Analisa** o sistema e identifica o que pode ser removido com segurança
- **Informa** você sobre as consequências de cada operação antes de executá-la
- **Espera pelo seu consentimento** — a resposta padrão é sempre NÃO
- **Move os dados do usuário para quarentena** nos modos de limpeza, possibilitando reversões
- **Nunca altera** dados de email, senhas, cookies, perfis de navegador ou documentos

## Requisitos

- macOS 10.15 Catalina ou mais recente (incluindo Sonoma, Sequoia, macOS 26.x)
- bash 3.2+ (pré-instalado no macOS)
- Python 3.10+ para as ferramentas auxiliares `dev-sync/` e análise segura do `plan.json` em `apply --from-plan`
- Opcional: `bc` (para cálculo de tamanhos), `mdfind` (Spotlight, pré-instalado)

## Instalação

### Teste Rápido — Instalador de linha única

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/KasprowiczM/macOS_cleanup/main/install.sh)"
```

O instalador **apenas clona o repositório e imprime os próximos passos** — não exclui nada nem inicia a limpeza. Ele instala em `~/Dev_Env/macOS_cleanup` por padrão (altere via `MACOS_CLEANUP_DIR=...`). Prefere revisar o código primeiro? Faça o download e inspecione [`install.sh`](install.sh) antes da execução.

### Instalação Manual

```bash
git clone https://github.com/KasprowiczM/macOS_cleanup.git ~/Dev_Env/macOS_cleanup
cd ~/Dev_Env/macOS_cleanup
chmod +x cleanup_all.sh
```

## Uso

### 1. Primeira Execução Recomendada — Análise (dry-run)

```bash
bash cleanup_all.sh
```

O script analisará seu sistema, mostrará o que pode ser limpo e perguntará se você deseja prosseguir. **Nada é excluído sem o seu consentimento.**

### 2. Limpeza Interativa Completa

```bash
bash cleanup_all.sh --interactive
```

Passa por cada categoria, explicando o que é, as consequências da exclusão, e pede sua permissão. A limpeza real padrão funciona no modo `--quarantine`: caminhos do usuário são movidos para `~/Library/Application Support/macOS_cleanup/quarantine` em vez de serem excluídos imediatamente.

Se você deseja liberar espaço permanentemente logo após a análise, execute o modo permanente:

```bash
bash cleanup_all.sh --interactive --permanent
```

### 3. Limpeza Automática Somente de Itens Seguros

```bash
bash cleanup_all.sh --auto-safe
```

Por padrão, isso apenas coloca em quarentena os caches de aplicativos explicitamente conhecidos e de baixo risco. Itens gerais de nível superior em `~/Library/Caches` são relatados para a decisão do usuário, pois podem incluir grandes caches offline que os aplicativos precisariam baixar novamente. Arquivos temporários e caminhos fora de `$HOME` requerem o modo `--permanent` porque não há reversão de quarentena sensata para eles:

```bash
bash cleanup_all.sh --auto-safe --permanent
```

Tudo o mais é relatado para a sua decisão.

### 4. Categoria Específica

```bash
bash cleanup_all.sh --interactive --category dev
bash cleanup_all.sh --dry-run --category user-caches
bash cleanup_all.sh --interactive --category time-machine
```

### 5. Analisar / planejar / aplicar

```bash
# Alias legível para fluxos de trabalho de agentes/operadores
bash cleanup_all.sh analyze

# Análise + plano JSON estrutural
bash cleanup_all.sh plan

# Executar o plano: somente SAFE por padrão
bash cleanup_all.sh apply --from-plan reports/plan_<run_id>.json

# Simular a execução do plano
bash cleanup_all.sh apply --from-plan reports/plan_<run_id>.json --dry-run
```

`plan.json` contém operações com `id`, caminho ou comando, categoria, classe `SAFE`/`REVIEW`/`DANGEROUS`, tamanho estimado, descrição das consequências e recomendação. `apply --from-plan` nunca executa `DANGEROUS`; `REVIEW` é ignorado a menos que você adicione `--include-review` e passe pela confirmação interativa.

### 6. Modo Não Interativo (CI/Automação)

```bash
# Análise sem prompts
bash cleanup_all.sh --dry-run --non-interactive

# Auto-safe sem confirmação manual (somente itens explicitamente seguros)
bash cleanup_all.sh --auto-safe --non-interactive --yes

# Recuperação de espaço real na automação: somente após um --permanent consciente
bash cleanup_all.sh --auto-safe --permanent --non-interactive --yes

# Executar uma categoria específica sem prompts
bash cleanup_all.sh --dry-run --non-interactive --category app-leftovers
```

`--non-interactive` executa o script sem ler a entrada do TTY.
Por segurança, toda pergunta é tratada como `não` por padrão.
`--yes` confirma somente operações de baixo risco; categorias médias/altas exigem o modo interativo.

### 7. Com Exclusão de Caminho

```bash
bash cleanup_all.sh --interactive --exclude "$HOME/Library/Caches/myapp"
```

### 8. Quarentena, Restauração e Limpeza Definitiva

```bash
# Listar execuções de quarentena salvas
bash cleanup_all.sh --list-quarantine

# Restaurar a última execução ou um manifesto específico
bash cleanup_all.sh --restore latest
bash cleanup_all.sh --restore reports/restore_<run_id>.tsv

# Visualizar a exclusão permanente da quarentena
bash cleanup_all.sh --purge-quarantine latest

# Liberar o espaço ocupado pela quarentena de fato
bash cleanup_all.sh --purge-quarantine latest --apply

# Excluir execuções mais antigas que o período de retenção
bash cleanup_all.sh --purge-quarantine expired --retention-days 30 --apply
```

A quarentena fornece uma reversão, mas não libera espaço em disco por si só. Você só recupera espaço após `--permanent` ou um `--purge-quarantine ... --apply` subsequente.

### 9. Eliminar logs e relatórios de execução antigos (`--prune-artifacts`)

```bash
bash cleanup_all.sh --prune-artifacts
```

Analyze, list, plan e dry-run nunca apagam logs ou diários. A retenção de artefactos é apenas este comando explícito. A idade é controlada por `ARTIFACT_RETENTION_DAYS` (0 desativa).

### 10. Saída JSON — Resultados Legíveis por Máquina (`--json`)

```bash
# Saída analítica (dry-run) no formato JSON em stdout
bash cleanup_all.sh --dry-run --non-interactive --json --category dev

# Combinar com um pipe (saída humana vai para stderr)
bash cleanup_all.sh plan --json --non-interactive 2>/dev/null | jq .counters

# Salvar JSON em um arquivo e pular o relatório Markdown
bash cleanup_all.sh --dry-run --non-interactive --json --category trash 2>/dev/null > summary.json
```

A flag `--json` redireciona todas as saídas legíveis (banners, seções, resumos) para **stderr** e emite um único objeto JSON para **stdout** no final da execução. O objeto contém:

| Campo | Descrição |
|-------|-------------|
| `mode` | Modo de execução (`dry-run`, `plan`, `apply-plan`, etc.) |
| `dry_run` | `true` / `false` |
| `analysis_status` | `complete` / `partial` |
| `categories` | Matriz de categorias ativas |
| `counters` | `would_free_bytes`, `cleaned_bytes`, `informational_bytes`, `quarantined_bytes`, `skipped_items`, `unreadable_paths`, `user_decisions_needed` |
| `plan` | Contadores para operações `SAFE`/`REVIEW`/`DANGEROUS` e bytes; `report_only_operations`, `report_only_bytes`, `executable_bytes` |
| `artifacts` | Caminhos para `report`, `plan`, `journal`, `restore_manifest` |
| `warnings` | Número de itens pulados |
| `user_decisions` | Lista de descrições de itens que exigem uma decisão |

A flag funciona com qualquer modo (`dry-run`, `plan`, `apply`, `--auto-safe`, etc.) e é segura para `--non-interactive` e CI. Não muda nenhum comportamento se não for fornecida.

## Categorias Disponíveis

| Categoria | Conteúdo |
|-----------|----------|
| `trash` | Conteúdo de ~/.Trash |
| `system` | Caches de sistema, arquivos antigos em /tmp e /private/tmp |
| `user-caches` | ~/Library/Caches (caches de apps do usuário) |
| `logs` | Registros antigos do sistema e de aplicativos |
| `app-leftovers` | Relatório heurístico de sobras; sem exclusão automática por padrão |
| `dev` | Xcode DerivedData, simuladores, caches de npm/pip/brew/docker |
| `time-machine` | Snapshots locais do TM + backups do iOS |
| `large-files` | Arquivos DMG/PKG/ISO antigos em ~/Downloads |

## Modelo de Segurança

### Filosofia: Consentimento Informado

O script opera sob um modelo de **consentimento informado**:

```
Analisar → Mostrar resultados → Explicar consequências → Avisos → Aguardar consentimento → Agir
```

A linguagem de destino UX/DX descreve esse fluxo como **analisar → planejar → aplicar**:

- `analyze` — dry-run sem mutação, ex., `bash cleanup_all.sh --dry-run`
- `plan` — relatório Markdown, journal JSONL e uma lista de itens que requerem decisão
- `apply` — ação real após o consentimento: `apply --from-plan`, `--interactive`, `--auto-safe`, ou `--purge-quarantine ... --apply`

Modelo detalhado para operadores e agentes: `docs/ux_dx_safety_model.md`.

### O que NUNCA é Tocado

<!-- BEGIN NEVER_TOUCH_PATHS -->
- `~/Library/Mail`
- `~/Library/Containers/com.apple.mail`
- `~/Library/Keychains`
- `/Library/Keychains`
- `/System/Library/Keychains`
- `~/Library/Application Support/1Password`
- `~/Library/Application Support/1Password 7`
- `~/Library/Application Support/com.agilebits`
- `~/Library/Application Support/Bitwarden`
- `~/Library/Application Support/LastPass`
- `~/Library/Application Support/Dashlane`
- `~/Library/Application Support/Enpass`
- `~/Library/Application Support/Keybase`
- `~/Library/Application Support/macOS_cleanup`
- `~/Library/Caches/com.1password.1password`
- `~/Library/Caches/com.agilebits.onepassword7`
- `~/Library/Caches/com.bitwarden.desktop`
- `~/Library/Caches/com.lastpass.LastPass`
- `~/Library/Caches/com.dashlane.Dashlane`
- `~/Library/Caches/in.sinew.Enpass-Desktop`
- `~/Documents`
- `~/Desktop`
- `~/Pictures/Photos Library.photoslibrary`
- `~/Pictures/Photos Library`
- `~/Music/Music/Music Library.musiclibrary`
- `~/Music/Music Library.musiclibrary`
- `~/Movies`
- `~/Library/Messages`
- `~/Library/Calendars`
- `~/Library/Application Support/AddressBook`
- `~/Library/Mobile Documents`
- `~/Library/CloudStorage`
- `~/Dropbox`
- `~/OneDrive`
- `~/Google Drive`
- `~/Library/Application Support/Google/DriveFS`
- `~/Library/Application Support/Google/Chrome`
- `~/Library/Application Support/Firefox`
- `~/Library/Application Support/Microsoft Edge`
- `~/Library/Application Support/BraveSoftware`
- `~/Library/Application Support/Opera`
- `~/Library/Application Support/Vivaldi`
- `~/Library/Safari`
- `~/Library/MobileDevice/Provisioning Profiles`
- `~/Library/Keychains`
- `~/Developer`
- `~/Projects`
- `~/src`
- `~/code`
- `~/repos`
- `~/.ssh`
- `~/.gnupg`
- `~/.aws/credentials`
- `~/.aws/config`
- `~/.aws/sso`
- `~/.gitconfig`
- `~/.git-credentials`
- `~/.config`
- `~/.kube`
- `~/.docker`
- `~/.netrc`
- `~/.zshrc`
- `~/.zprofile`
- `~/.zsh_history`
- `~/.bash_profile`
- `~/.bashrc`
- `~/.bash_history`
- `~/.profile`
- `~/.npmrc`
- `~/.config/gh`
<!-- END NEVER_TOUCH_PATHS -->

### Níveis de Segurança das Regras

- `SAFE` — artefatos reproduzíveis, ex., caches de apps conhecidos; pode entrar em `--auto-safe`, ainda passando por validações
- `REVIEW` — exige um plano e decisão do usuário, ex., caches gerais, logs, artefatos de compilação, backups do iOS
- `DANGEROUS` — dados do usuário, identidade, perfis, e-mail, senhas; não é excluído automaticamente

O arquivo `cleanup_rules.yaml` atual mantém os valores técnicos `safe`, `ask`, `never`. O mapeamento UX/DX corresponde a `SAFE`, `REVIEW`, `DANGEROUS`.

### Journal e Rollback (Reversão)

Cada relatório salva um resumo automático do plano em `reports/journal_*.jsonl` (`report_generated`, `category_total`). Operações reais de `safe_remove()` adicionam eventos de execução, ex., `quarantined`, `deleted`, `skipped_non_user_scope`. Comandos nativos controlados, como `brew cleanup`, `docker system prune`, `xcrun simctl delete unavailable`, e `tmutil deletelocalsnapshots`, anexam eventos `native_command` porque não têm reversão de quarentena. A quarentena também gera `reports/restore_*.tsv`, que é usado por `--restore`. O processo de restauração recusa recuperar fora do diretório do usuário, para caminhos protegidos, por diretórios pais com link simbólico ou a partir de arquivos fora do diretório da quarentena.

Quarentena é uma reversão, não um backup. Antes da primeira limpeza real, o usuário ainda deve ter um backup de sistema recente. O e-mail e os perfis de navegador são tratados apenas como diretrizes: os caches podem ser relatados, mas os dados da conta, sessões, cookies, favoritos e repositórios de mensagens locais ficam fora da limpeza automática.

## Estrutura do Projeto

```
macOS_cleanup/
├── cleanup_all.sh          # Script principal — ponto de entrada
├── cleanup_rules.yaml      # Base de conhecimento: regras de limpeza por aplicativo
├── config/
│   └── defaults.sh         # Configuração padrão, limites de idade, caminhos protegidos
├── lib/
│   ├── common.sh           # Logging, formatação, safe_remove(), proteção de caminho
│   ├── policy.sh           # Parser de políticas YAML e mapeamento SAFE/REVIEW/DANGEROUS
│   ├── analyzer.sh         # Análise do sistema (todas as funções analyze_*)
│   ├── cleaner.sh          # Motor de limpeza (todas as funções clean_*)
│   ├── planner.sh          # plan.json e apply --from-plan
│   ├── interactive.sh      # Avisos e confirmações do usuário
│   └── reporter.sh         # Gerador de relatórios Markdown
├── docs/
│   ├── rules_design.md     # Documentação da estrutura das regras
│   └── ux_dx_safety_model.md # Modelo SAFE/REVIEW/DANGEROUS e analyze/plan/apply
├── tests/                  # Cenários de teste
└── AGENTS.md               # O papel dos agentes de IA no projeto
```

## Relatórios e Logs

Após cada execução, o script gera:

- **Log**: `logs/cleanup_YYYY-MM-DD_HHMMSS_PID.log` — diário completo de operações
- **Relatório**: `reports/report_YYYY-MM-DD_HHMMSS_PID.md` — Resumo em Markdown
- **Plano**: `reports/plan_YYYY-MM-DD_HHMMSS_PID.json` — plano estrutural `SAFE`/`REVIEW`/`DANGEROUS`
- **Journal**: `reports/journal_YYYY-MM-DD_HHMMSS_PID.jsonl` — plano de máquina e registro de auditoria
- **Manifesto de Restauração**: `reports/restore_YYYY-MM-DD_HHMMSS_PID.tsv` — caminhos necessários para reversão da quarentena

```bash
# Abrir o último relatório
open reports/$(ls -t reports/ | head -1)
```

## Expansão e Configuração

### Adicionando um Novo Aplicativo à Base de Regras

Edite o arquivo `cleanup_rules.yaml` e adicione uma entrada seguindo este esquema:

```yaml
- name: "Nome do App"
  bundle_ids:
    - "com.vendor.appname"
  type: dev-tool   # browser|mail|dev-tool|media-editor|system|...
  paths:
    - path: "~/Library/Caches/com.vendor.appname"
      type: cache
      safety: ask   # safe | ask | never
      notes: "Descrição do que é isso e se é seguro"
```

### Alterando Limites de Idade

Edite `config/defaults.sh`:

```bash
LOG_MAX_AGE_DAYS=30       # Logs mais antigos que N dias
TMP_MAX_AGE_HOURS=24      # Arquivos tmp mais antigos que N horas
DMG_MAX_AGE_DAYS=30       # DMG/PKG em ~/Downloads
```

## Aviso Legal

> **Use este script por sua própria conta e risco.** O script é desenvolvido com segurança em mente e sempre pergunta antes de deletar, mas nenhum software é isento de bugs. Certifique-se de ter um backup recente antes de executar em um modo que não seja dry-run pela primeira vez.

---

Projeto: `macOS_cleanup` | Versão: 2.1.0 | Licença: MIT
