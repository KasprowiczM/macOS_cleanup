[🇺🇸 EN](user_guide.md) | [🇵🇱 PL](user_guide.pl.md) | [🇪🇸 ES](user_guide.es.md) | [🇫🇷 FR](user_guide.fr.md) | [🇩🇪 DE](user_guide.de.md) | [🇮🇹 IT](user_guide.it.md) | [🇵🇹 PT](user_guide.pt.md)

---

# macOS Cleanup — Guia do Usuário

Este documento pressupõe que você não precisa conhecer a estrutura do `~/Library` ou como os caches funcionam. O objetivo é recuperar espaço com segurança sem excluir e-mails, senhas, documentos, perfis de navegador, projetos e configurações de aplicativos.

## A Regra de Ouro

Não execute a limpeza "às cegas". Faça sempre uma análise primeiro:

```bash
bash cleanup_all.sh --dry-run --non-interactive --no-color
```

Isso não exclui nada. O script mostrará:

- quanto espaço pode ser potencialmente recuperado,
- quais itens são `SAFE` (seguros),
- quais itens requerem `REVIEW` (revisão),
- quais itens são `DANGEROUS` (perigosos) e não serão excluídos automaticamente.

## Classes de Risco

| Classe | Significado | O que o script faz |
|-------|------------|----------------|
| `SAFE` | Dados recriáveis: caches de apps, caches de build, logs antigos, tmp. | Pode ser excluído no `auto-safe` ou executado a partir de um plano. Por padrão, envia arquivos do usuário para quarentena. |
| `REVIEW` | O espaço pode ser recuperado, mas pode haver um custo: baixar novamente, inicialização mais lenta, perda de logs de diagnóstico, estado de emuladores. | Mostrado no plano. Não excluído automaticamente sem uma decisão consciente. |
| `DANGEROUS` | E-mail, perfis de navegador, senhas, documentos, configurações, dados de aplicativos ativos. | Apenas relata ou bloqueia. Nunca exclui automaticamente. |

Se você não entender um item no relatório, trate-o como `REVIEW` ou `DANGEROUS`.

## Backup e Quarentena

A limpeza real exige um backup recente do Time Machine. Se o script não puder verificá-lo, a limpeza será bloqueada. Você pode forçar a execução usando:

```bash
bash cleanup_all.sh --auto-safe --allow-no-backup
```

Use isso apenas se aceitar conscientemente o risco.

A quarentena não libera espaço imediatamente. Por padrão, os arquivos do usuário vão para:

```text
~/Library/Application Support/macOS_cleanup/quarantine/<run_id>/
```

Você só recuperará o espaço usando `--permanent` ou uma limpeza posterior:

```bash
bash cleanup_all.sh --purge-quarantine latest --apply
```

Restaurar:

```bash
bash cleanup_all.sh --restore latest
```

## Fluxo de Trabalho Mais Seguro

### 1. Análise

```bash
bash cleanup_all.sh --dry-run --non-interactive --no-color
```

Leia o relatório em `reports/report_*.md`.

### 2. Plano JSON

```bash
bash cleanup_all.sh plan --non-interactive --no-color
```

O plano é salvo em `reports/plan_*.json`. Cada operação possui um `id`, `risk`, `path`, `description` e `recommendation`.

### 3. Limpeza Mais Segura

```bash
bash cleanup_all.sh --auto-safe --non-interactive --yes
```

Isso limpa apenas caches de apps explicitamente conhecidos como `SAFE`. Se não houver backup verificado:

```bash
bash cleanup_all.sh --auto-safe --non-interactive --yes --allow-no-backup
```

### 4. Revisão Interativa para Itens Maiores

```bash
bash cleanup_all.sh --interactive
```

O script mostrará a categoria, tamanho, consequências e perguntará. A resposta padrão é sempre `no`.

## O que pode ser excluído sem grandes consequências

Os itens a seguir costumam ser `SAFE`, mas ainda podem causar uma inicialização mais lenta do aplicativo na primeira vez:

- Cache do Slack/Teams/Discord: o aplicativo recriará os ativos web e miniaturas.
- `Cache` e `Code Cache` do VS Code/Cursor: o editor reconstruirá o cache; projetos e configurações permanecem.
- `Cache` padrão do Spotify: músicas/podcasts serão baixados novamente.
- Cache do Zoom: não exclui gravações de `Documents/Zoom`.
- Xcode DerivedData: O Xcode reconstruirá os projetos do zero.
- Cache do npm/pnpm/yarn/pip/Homebrew: dependências serão baixadas novamente.
- logs antigos: você perde o histórico de diagnóstico, mas não os dados do aplicativo.
- arquivos `/tmp` antigos: temporários, o macOS geralmente os limpa sozinho.

## O que Exige Análise

### Geral `~/Library/Caches`

O script mostra itens de nível superior de `~/Library/Caches` como `REVIEW`, porque nem todos os caches são baratos para recriar. Alguns aplicativos mantêm grandes dados offline, mapas, mídia, modelos de IA ou caches de trabalho lá.

O que verificar:

- você reconhece o aplicativo pelo nome da pasta?
- o aplicativo possui dados offline?
- você aceita baixar novamente gigabytes de dados?
- você não está trabalhando offline no momento?

### JetBrains

O cache da JetBrains pode ser grande. A exclusão não apaga os projetos, mas a IDE reconstruirá seus índices. Isso pode demorar muito e exigir muito da CPU. Exclua apenas quando tiver tempo para a reindexação.

### Cache de Mídia da Adobe

Não exclui projetos de origem ou mídia, mas Premiere/After Effects podem precisar regenerar visualizações, ajustar áudio/vídeo e caches. Exclua apenas se você tiver a mídia original e aceitar uma primeira abertura do projeto mais lenta.

### Figma

O cache geralmente é recriável, mas pode afetar a reabertura de arquivos grandes e o trabalho offline. Prefira revisar.

### Spotify PersistentCache

Pode significar dados maiores de streaming/offline. A exclusão pode forçar novos downloads. O `Spotify Cache` normal é mais seguro que o `PersistentCache`.

### Suporte a Dispositivos Xcode

São símbolos de depuração para dispositivos iOS/watchOS/tvOS. O Xcode os baixará novamente ao conectar um dispositivo com uma versão específica do sistema operacional. Exclua apenas se você não depura dispositivos antigos ou se tem tempo e internet.

### Arquivos Xcode

Arquivos `.xcarchive` podem ser necessários para a App Store, simbolização de falhas (crashes) e recriação de compilações. O script apenas relata-os. Exclua manualmente a partir do Xcode Organizer após verificar.

### Runtimes do simulador

Os runtimes que o `simctl` marca como inutilizáveis ficam num armazenamento gerido pelo sistema. O script nunca os remove com `rm`: em `--interactive` executa `xcrun simctl runtime delete --unusable` depois do seu consentimento e não o faz enquanto Xcode, Simulator ou xcodebuild estiverem em execução. Os planos apenas os reportam. O Xcode pode baixar um runtime novamente. Verifique:

```bash
xcrun simctl runtime delete --unusable --dry-run
```

### Docker

`docker system prune -f` exclui imagens, contêineres parados, redes e caches de build. Não exclui volumes, mas contêineres parados podem conter estado que você ainda não moveu para um volume. Verifique:

```bash
docker ps -a
docker system df
```

### Android AVD

Emuladores Android podem conter estados locais de aplicativos de teste. Exclua via Android Studio Device Manager, e não através de um `rm` manual, se não tiver certeza.

### Maven `~/.m2/repository`

Pode conter artefatos compilados localmente indisponíveis na internet. O script trata isso apenas como revisão.

### Backups iOS

São cópias do iPhone/iPad. Exclua apenas se você tiver um backup recente no iCloud ou um novo backup no Finder.

### Snapshots locais do Time Machine

O macOS os exclui automaticamente quando precisa de espaço. A limpeza manual só faz sentido se você entende que está perdendo pontos de restauração locais.

## O Que o Script NÃO Exclui Automaticamente

### Apple Mail

`~/Library/Mail` e `~/Library/Containers/com.apple.mail` podem conter mensagens, anexos, contas POP, índices e arquivos locais. O script mostra apenas os tamanhos e as maiores áreas.

Ações seguras:

- no Mail.app, exclua as mensagens grandes,
- esvazie o Lixo e o Spam no Mail.app,
- verifique os anexos,
- exporte as caixas de correio locais antes de qualquer intervenção manual.

### Navegadores

Perfis do Chrome/Firefox/Safari/Edge/Brave contêm cookies, sessões, senhas, histórico, favoritos e extensões. O script não os exclui.

Limpe os dados dos sites pela interface do usuário:

- Safari: Ajustes -> Privacidade -> Gerenciar Dados de Sites.
- Chrome/Brave/Edge: `chrome://settings/clearBrowserData`.
- Firefox: Configurações -> Privacidade e Segurança -> Cookies e Dados de Sites.

Excluir cookies pode desconectar você dos sites.

### Application Support e Preferências

`~/Library/Application Support` e `~/Library/Preferences` costumam conter bancos de dados, configurações, licenças, projetos locais e definições. O script não exclui dados de aplicativos ativos. Sobras de aplicativos desinstalados são apenas relatadas.

## Como Ler o `plan.json`

Exemplo:

```json
{
  "id": "op-0007",
  "category": "app-caches",
  "risk": "SAFE",
  "action": "remove_path",
  "path": "/Users/me/Library/Caches/com.spotify.client",
  "estimated_bytes": 532000000,
  "description": "Spotify cache: streaming cache muzyki/podcastów.",
  "recommendation": "SAFE: można usunąć przez auto-safe..."
}
```

Interpretação:

- `SAFE`: pode ser executado via `apply --from-plan`.
- `REVIEW`: exige uma decisão manual.
- `DANGEROUS`: não será executado.
- `native_command`: o script executará uma ferramenta como `brew cleanup`; normalmente sem retorno da quarentena.
- `report_only`: apenas informação, sem exclusão.

## Exemplos de Decisões

| Situação | Decisão |
|----------|---------|
| Você quer recuperar rapidamente algum espaço sem riscos | `--auto-safe` |
| Você tem bastante cache npm/pnpm e internet | limpe a categoria `dev` após revisão |
| Você tem um perfil grande no Chrome/Firefox | não exclua manualmente, use a interface do navegador |
| `~/Library/Mail` grande | limpe a partir do Mail.app, não pelo script |
| `Xcode Archives` grandes | verifique no Xcode Organizer |
| Sem backup do Time Machine | não aplique de verdade, a não ser que use conscientemente o `--allow-no-backup` |

## Comandos Úteis

```bash
# Analisar tudo
bash cleanup_all.sh --dry-run --non-interactive --no-color

# Plano JSON
bash cleanup_all.sh plan --non-interactive --no-color

# Apenas cache de desenvolvedor
bash cleanup_all.sh --dry-run --category dev --non-interactive --no-color

# Limpeza mais segura
bash cleanup_all.sh --auto-safe --non-interactive --yes

# Interativo, com perguntas completas
bash cleanup_all.sh --interactive

# Simular a execução do plano
bash cleanup_all.sh apply --from-plan reports/plan_<run_id>.json --dry-run --non-interactive --no-color

# Restaurar da quarentena
bash cleanup_all.sh --restore latest

# Liberar espaço da quarentena após verificação
bash cleanup_all.sh --purge-quarantine latest --apply
```

## Quando Abortar

Aborte e não confirme a limpeza se:

- você não tiver um backup,
- você não entender o caminho,
- relacionar-se a e-mail, navegadores, senhas, documentos ou configurações,
- você estiver no meio de um diagnóstico de falha e precisar dos logs,
- o aplicativo possuir dados offline que você não deseja baixar novamente.

Uma limpeza segura consiste em recuperar espaço a partir de dados recriáveis, não excluir tudo que for grande.
