[EN](README.md) | [PL](README.pl.md) | [ES](README.es.md) | [FR](README.fr.md) | [DE](README.de.md) | [IT](README.it.md) | [PT](README.pt.md)

<p align="center">
  <a href="https://macos-cleanup.64bit.site/"><img src="assets/brand-banner.svg" alt="macOS Cleanup" width="640" /></a>
</p>

# macOS Cleanup

**Versão 4.0.5** · Mac com Apple Silicon · macOS 11 ou posterior · [Site](https://macos-cleanup.64bit.site/) · [Suporte](https://macos-cleanup.64bit.site/support) · [Licença MIT](LICENSE) · [Alterações](CHANGELOG.md)

Uma ferramenta local para limpar o disco com cuidado no macOS. Primeiro mede, depois mostra-lhe um plano e só atua sobre aquilo que aprovar. A maioria das remoções vai para uma pasta de quarentena de onde as pode restaurar. Tem uma interface de terminal e um modo simples de linha de comandos, e nunca usa `sudo`.

## O que limpa

Cada categoria tem um nível (tier). O nível decide como a ferramenta a trata.

**Regeneráveis (regenerable).** O proprietário dos dados reconstrói-os. «Limpeza segura» e uma execução automática só tocam nas categorias cujo modo é `auto`. De origem, isso é apenas `app-caches`; todas as outras categorias regeneráveis começam em `review`. No separador Categorias (`m`) pode passar para `auto` uma categoria regenerável que vai para a quarentena. `npm`, `yarn`, `pnpm` e `pip` executam uma ferramenta nativa e nunca podem ser `auto`.

| Categoria | O que é | Desfazer |
|-----------|---------|--------|
| `app-caches` | Caches de aplicações de uma lista de permitidas incorporada | restaurável |
| `xcode-derived` | Xcode DerivedData | restaurável |
| `npx`, `gradle`, `cocoapods`, `cargo`, `swift-pm`, `bundler`, `composer` | Caches de compilação e de pacotes, removidas movendo-as para a quarentena | restaurável |
| `npm`, `yarn`, `pnpm`, `pip` | Caches de gestores de pacotes, limpas pela própria ferramenta (`npm cache clean --force`, `yarn cache clean`, `pnpm store prune`, `pip cache purge`) | permanente |

**Revisão (review).** Dispendiosas de reconstruir ou visíveis para si. Cada uma precisa do seu consentimento na sessão. Nunca fazem parte de uma execução automática.

| Categoria | O que é | Desfazer |
|-----------|---------|--------|
| `trash` | O conteúdo do Lixo | restaurável |
| `user-caches` | Outros itens de `~/Library/Caches` | restaurável |
| `app-caches-review` | Caches de aplicações conhecidas que podem conter dados offline ou demorar a reconstruir | restaurável |
| `user-logs`, `diagnostic-reports` | Registos antigos e relatórios de falhas na sua pasta pessoal | restaurável |
| `device-support` | Pastas antigas de iOS Device Support (a mais recente por plataforma é mantida) | restaurável |
| `pnpm-stale` | Dados obsoletos do armazém do pnpm | restaurável |
| `ios-backups` | Cópias de segurança de dispositivos iOS, confirmadas uma a uma | restaurável |
| `installers` | Ficheiros DMG, PKG e ISO antigos em Transferências | restaurável |
| `system-logs`, `tmp` | Registos do sistema e ficheiros temporários fora da sua pasta pessoal | permanente, e apenas no modo permanente |
| `simulators`, `sim-runtimes` | Simuladores indisponíveis e ambientes de execução de simulador inutilizáveis (`xcrun simctl`) | permanente |
| `brew`, `gem` | `brew cleanup --prune=all` e `gem cleanup`, que removem versões antigas instaladas | permanente |
| `docker` | `docker system prune -f` | permanente |
| `tm-snapshots` | Instantâneos locais do Time Machine (`tmutil`); o mais recente é mantido | permanente |

`sim-runtimes`, `docker` e `tm-snapshots` só são executadas quando as escolhe numa execução interativa, nunca a partir de «Limpeza segura» nem numa execução automática.

**Só relatório (report only).** Medidas e explicadas, nunca removidas por esta ferramenta: `system-caches`, `xcode-archives`, `maven`, `android-avd`, `app-leftovers`, `browser-caches`, `browser-data`, `mail-data` e `mail-downloads`.

## Como o protege

- **Nada muda até concordar.** Uma análise ou uma pré-visualização nunca toca nos seus ficheiros. A resposta predefinida a cada pergunta é não.
- **Quarentena, não eliminação.** Quando a ferramenta move ficheiros por si própria, move-os para uma pasta de quarentena no mesmo disco e regista o que moveu, para que `restore` os possa repor. A quarentena não liberta espaço até a purgar.
- **Os passos permanentes estão identificados.** As limpezas com ferramentas nativas (`npm`, `yarn`, `pnpm`, `pip`, `brew`, `gem`, `docker`, `xcrun simctl`, `tmutil`) não podem ser desfeitas e, por isso, também não restauradas. O modo permanente também elimina definitivamente. A interface e as perguntas dizem-no sempre.
- **Uma lista protegida que continua protegida.** Mail, Mensagens, Calendários, Contactos, porta-chaves, gestores de palavras-passe, perfis de navegadores, Documentos, Secretária, bibliotecas de Fotografias, Música e Filmes, iCloud e outras pastas na nuvem, chaves SSH e GPG, ficheiros de credenciais, `~/.config`, pastas de código-fonte e árvores de trabalho Git nunca são tocados. Tal como o programa, as definições, o estado e a quarentena desta própria ferramenta.
- **Verificado de novo mesmo antes de agir.** Mesmo antes de remover um item, a ferramenta verifica que ainda existe, que é o mesmo item que foi planeado, que está dentro das pastas permitidas da sua categoria, que não está em uso e que não é demasiado recente se tiver definido uma idade mínima.
- **As execuções automáticas são muito restritas.** Estão desativadas por predefinição. Quando as ativa, só tocam nas categorias cujo modo é `auto` (de origem apenas `app-caches`), apenas através da quarentena, e depois purgam as execuções de quarentena cujo período de retenção terminou. Não executam nenhuma ferramenta nativa e nunca usam o modo permanente.
- **Números honestos.** Os resultados mostram uma estimativa (a soma dos tamanhos daquilo sobre que a execução atuou) e, quando é possível medir, a variação real do espaço livre. Muitas vezes diferem, e a interface explica porquê. Os tamanhos são apresentados em unidades binárias: KiB, MiB, GiB.

A quarentena é uma forma de desfazer, não uma cópia de segurança. Faça uma cópia de segurança atual antes da sua primeira limpeza real.

## Requisitos

- Mac com Apple Silicon e macOS 11 Big Sur ou posterior. Os Mac com Intel não são bloqueados pelo código, mas ficam fora do suporte oficial.
- `bash` 3.2 ou posterior, que o macOS inclui.
- Python 3.9 ou posterior para a interface de terminal, para os planos (`plan` e `apply`) e para `migrate`. Se faltar, execute `xcode-select --install`. Sem Python, o modo simples de linha de comandos continua a funcionar para os restantes comandos.
- Um terminal com pelo menos 40 colunas por 12 linhas para a interface.
- Acesso à rede apenas para instalar e para uma atualização que o próprio utilizador inicia com `macos-cleanup update-self`. Limpar, analisar e restaurar nunca usam a rede.

## Instalação

```bash
/bin/bash -c "$(curl -fsSL https://github.com/KasprowiczM/macOS_cleanup/releases/latest/download/install.sh)"
```

O instalador descarrega o pacote da versão e o respetivo ficheiro `SHA256SUMS`, verifica a soma de verificação, coloca o programa em `~/.local/share/macos-cleanup` e cria a ligação `~/.local/bin/macos-cleanup`. Não precisa de `git`, nunca usa `sudo`, nunca altera as suas definições, o seu estado nem a sua quarentena, nunca instala a execução automática e nunca inicia uma limpeza. Para instalar uma versão específica: `install.sh --version 4.0.5`.

Para verificar primeiro o descarregamento por si:

```bash
curl -fsSLO https://github.com/KasprowiczM/macOS_cleanup/releases/download/v4.0.5/macos-cleanup-4.0.5.tar.gz
curl -fsSLO https://github.com/KasprowiczM/macOS_cleanup/releases/download/v4.0.5/SHA256SUMS
shasum -a 256 -c SHA256SUMS --ignore-missing
```

Só descomprima o pacote se a verificação mostrar `OK`. As somas de verificação protegem contra um descarregamento danificado ou incompleto. As versões não são assinadas criptograficamente, pelo que uma soma de verificação obtida no mesmo local do pacote não prova quem o publicou. Mais opções e passos manuais: [INSTALL.md](docs/user/INSTALL.md) (em inglês).

Se depois o `macos-cleanup` não for encontrado, abra uma nova janela de terminal e verifique se `~/.local/bin` está no seu `PATH`.

## Primeira execução

```bash
macos-cleanup
```

Num terminal, isto abre a interface no Início. Sem terminal, um simples `macos-cleanup` é uma análise só de leitura. Prima `S` para analisar. Uma análise não altera nada. Prima `P` para uma pré-visualização do que uma limpeza faria e depois `C` para limpar as categorias seguras, ou escolha categorias no separador Categorias e prima `X`.

`mac-cleanup` é o mesmo comando que `macos-cleanup`, e ambos funcionam a partir de qualquer pasta. Sem argumentos, cada um abre a interface; `--cli` corre em modo de terminal simples. O instalador avisa-o quando outro programa no seu `PATH` responde a um dos dois nomes: escrever esse nome executaria então esse programa, e não o macOS Cleanup.

Em texto simples, em alternativa:

```bash
macos-cleanup scan
```

Antes de fazer algo real, execute `macos-cleanup doctor` para ver os seus caminhos, o espaço livre, o estado do Acesso Total ao Disco e os instantâneos locais.

## A interface de terminal

Sete separadores, acessíveis com `1` a `7`:

| # | Separador | Para que serve |
|---|-----------|----------------|
| 1 | Início | Analisar, pré-visualizar, limpar. Progresso em direto por categoria e o resultado da última execução |
| 2 | Categorias | Cada categoria com o seu nível, modo e tamanho. Aqui escolhe o que limpar |
| 3 | Quarentena | Restaurar uma execução, purgar uma execução (escreve a última parte do seu id), purgar as execuções expiradas |
| 4 | Histórico | Execuções anteriores e os seus relatórios. Aplicar um plano recente |
| 5 | Definições | Idioma e aspeto, limites de segurança, regras, retenção, agendamento, caminhos, exportar e importar |
| 6 | Diagnóstico | Verificações de estado, Acesso Total ao Disco, pré-visualização da migração da estrutura |
| 7 | Ajuda | Teclas, níveis, caminhos, versão |

Teclas principais: as setas movem, `Enter` abre ou confirma, `Tab` muda de painel, `Esc` volta atrás (ou pergunta se deve parar uma tarefa em curso), `1` a `7` saltam para um separador, `?` abre a ajuda, `L` mostra o registo, `q` sai. `/` pesquisa e `s` ordena nas listas que o oferecem. A linha inferior mostra sempre as teclas que funcionam nesse momento. Detalhes completos: [USER_GUIDE.md](docs/user/USER_GUIDE.md) (em inglês).

## Utilização simples na linha de comandos

`macos-cleanup` com um subcomando nunca abre a interface. O mesmo vale para `--cli` e para qualquer execução sem terminal. Um simples `macos-cleanup` sem terminal é uma análise só de leitura.

```bash
macos-cleanup scan                        # medir, não alterar nada
macos-cleanup plan                        # medir e escrever um ficheiro de plano
macos-cleanup clean --safe                # categorias em modo auto, após uma pergunta
macos-cleanup clean --only trash,npm      # exatamente estas categorias, com uma pergunta por secção
macos-cleanup quarantine list             # listar os pontos de restauro
macos-cleanup restore latest              # repor a última execução
macos-cleanup quarantine purge expired --apply   # remover definitivamente os pontos de restauro expirados
macos-cleanup doctor                      # verificar este Mac
macos-cleanup history                     # listar as execuções anteriores
```

`scan`, `plan`, `quarantine list`, `history` e `doctor` são só de leitura. `clean`, `apply`, `restore` e `quarantine purge ... --apply` alteram coisas. `quarantine purge` sem `--apply` apenas mostra uma pré-visualização. Uma restauração nunca substitui nada: um item cujo local original está ocupado é ignorado e permanece na quarentena, e a restauração termina então com um aviso (estado de saída 1), não com uma falha. Veja a tabela de todos os comandos e opções no [guia do utilizador](docs/user/USER_GUIDE.md) (em inglês).

## Onde ficam os ficheiros

| O quê | Onde | Substituição |
|-------|------|--------------|
| Programa | `~/.local/share/macos-cleanup` | `MACOS_CLEANUP_HOME` |
| Definições e regras | `~/.config/macos-cleanup` | `MACOS_CLEANUP_CONFIG_DIR` |
| Registos, relatórios, planos, histórico | `~/.local/state/macos-cleanup` | `MACOS_CLEANUP_STATE_DIR` |
| Quarentena (pontos de restauro) | `~/Library/Application Support/macOS_cleanup/quarantine` | `MACOS_CLEANUP_QUARANTINE_DIR` |

As substituições têm de ser caminhos absolutos. A quarentena tem de estar no mesmo disco que a sua pasta pessoal. Atualizar substitui apenas o programa. As definições, o estado e a quarentena permanecem.

## Execuções automáticas

Desativadas por predefinição, e o instalador nunca as ativa. Ativa-as em **Definições**, ou com:

```bash
macos-cleanup schedule install --time 10:30
macos-cleanup schedule status
macos-cleanup schedule remove
```

Isto instala um LaunchAgent do macOS (`com.github.kasprowiczm.macos-cleanup`). Uma execução agendada faz apenas duas coisas: move para a quarentena itens das categorias cujo modo é `auto` (de origem apenas `app-caches`) e purga as execuções de quarentena cujo período de retenção terminou. Não executa nenhuma ferramenta nativa, nada do nível «revisão» e nunca o modo permanente. Escreve uma entrada normal no Histórico.

## Atualizar e desinstalar

Execute de novo o instalador, ou `macos-cleanup update-self`, para atualizar. A versão anterior fica guardada junto do programa como `.previous`. Para remover a ferramenta:

```bash
macos-cleanup uninstall --dry-run
macos-cleanup uninstall
```

Pergunta se quer manter as suas definições e o histórico de execuções, e nunca elimina a quarentena a menos que passe `--purge-quarantine --yes`. Veja [UNINSTALL.md](docs/user/UNINSTALL.md) (em inglês). Vem da versão 3.x? Leia [MIGRATING_FROM_V3.md](docs/user/MIGRATING_FROM_V3.md) (em inglês).

## Privacidade

Analisar, limpar e restaurar funcionam offline; a rede só é usada para instalar e para `update-self`. A ferramenta não envia para lado nenhum caminhos, resultados nem dados de utilização, e não tem telemetria. Os registos, relatórios e planos ficam na pasta de estado do seu Mac. Use `--redact` para substituir a sua pasta pessoal por `~` e omitir o seu nome de utilizador e do equipamento antes de partilhar um relatório.

## Limites e lacunas conhecidas

- A quarentena não liberta espaço até a purgar, e os instantâneos locais podem depois reter blocos eliminados. O espaço volta quando o macOS o recupera.
- Os tamanhos são estimativas por excesso. Os clones do APFS e os blocos partilhados não são detetados.
- Sem Acesso Total ao Disco, algumas pastas não podem ser lidas. A análise fica então marcada como parcial e esses tamanhos são limites inferiores.
- As limpezas com ferramentas nativas e o modo permanente não podem ser desfeitos.
- As categorias «só relatório» nunca são removidas. Limpe-as com as suas próprias ferramentas.
- As versões são verificadas por soma de verificação, não por assinatura criptográfica.
- Apple Silicon com macOS 11 ou posterior é a configuração suportada. As outras configurações não foram testadas.

## Documentação

[Guia do utilizador](docs/user/USER_GUIDE.md) · [Instalação](docs/user/INSTALL.md) · [Desinstalação](docs/user/UNINSTALL.md) · [Migrar da 3.x](docs/user/MIGRATING_FROM_V3.md) · [Alterações](CHANGELOG.md) (todos em inglês)

## Suporte

[macos-cleanup.64bit.site/support](https://macos-cleanup.64bit.site/support)

## Licença

[MIT](LICENSE)

> **Utilize por sua conta e risco.** A ferramenta foi concebida para perguntar antes de agir e para manter aberto o caminho de volta, mas nenhum software está livre de erros. Faça primeiro uma cópia de segurança.
