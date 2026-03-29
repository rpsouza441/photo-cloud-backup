# Photo Cloud Backup

Projeto para automatizar o envio de fotos e videos de uma pasta local para um destino remoto via `rclone`, sem alterar a estrutura da origem.

No destino, os arquivos sao organizados por categoria e ano dentro da base configurada no `.env`:

- `<BASE>/<JPG>/<ANO>`
- `<BASE>/<VIDEO>/<ANO>`

O script usa `rclone copyto`, nunca `sync`, entao delecoes locais nao sao propagadas para o destino remoto.

## Estrutura

```text
photo-cloud-backup/
├── .env.example
├── .gitignore
├── README.md
├── logs/
├── scripts/
│   └── sync-onedrive-media.sh
├── state/
└── systemd/
    ├── photo-cloud-backup.service
    └── photo-cloud-backup.timer
```

## O que cada arquivo faz

- `.env.example`: modelo de configuracao. Define origem, remote do `rclone`, pasta base no destino, categorias, estrategia de ano e flags extras.
- `.gitignore`: impede que configuracoes locais, logs e estado do processamento entrem no Git.
- `README.md`: documentacao do projeto, fluxo, instalacao e operacao.
- `logs/.gitkeep`: mantem a pasta de logs versionada sem subir logs reais.
- `state/.gitkeep`: mantem a pasta de estado versionada sem subir arquivos de controle reais.
- `scripts/sync-onedrive-media.sh`: script principal. Varre a origem, classifica foto ou video, detecta o ano e copia para o destino remoto.
- `systemd/photo-cloud-backup.service`: exemplo de unidade `systemd` para rodar o script em modo `oneshot`.
- `systemd/photo-cloud-backup.timer`: exemplo de agendamento semanal para disparar o service automaticamente.

## Fluxo

1. A origem continua como uma pasta normal no filesystem.
2. O script percorre os arquivos localmente.
3. Cada arquivo e classificado como foto ou video.
4. O ano e definido via `mtime` ou `exiftool`.
5. O arquivo e copiado para o destino remoto no caminho final.
6. A origem nao e modificada.
7. Delecoes no destino continuam manuais.

## Configuracao

1. Copie o arquivo de exemplo:

```bash
cp .env.example .env
```

2. Edite pelo menos estas variaveis:

- `SOURCE_DIR`
- `RCLONE_REMOTE`
- `RCLONE_REMOTE_BASE`

3. Se quiser evitar colisoes de nomes iguais no mesmo ano, troque:

```env
DESTINATION_LAYOUT=year_relative
```

Esse modo preserva o caminho relativo da origem abaixo da pasta do ano.

Os caminhos reais do seu remote ficam somente no `.env`, que nao entra no Git.

## Arquivos locais que nao devem ir para o Git

- `.env`: contem caminhos reais, nomes de remote e ajustes locais.
- `logs/*`: contem historico de execucao.
- `state/*`: contem o estado dos arquivos ja processados.

## Dependencias

- `bash`
- `find`
- `stat`
- `rclone`
- `exiftool` opcional, somente se `YEAR_SOURCE=exif_or_mtime`

## Teste manual

```bash
bash scripts/sync-onedrive-media.sh --dry-run
```

## Execucao real

```bash
bash scripts/sync-onedrive-media.sh
```

## Instalar no systemd

Os arquivos em `systemd/` sao exemplos. Antes de instalar, ajuste o caminho do projeto no service para o diretorio real em que voce salvou este repositorio.

Copie a unidade e o timer:

```bash
sudo cp systemd/photo-cloud-backup.service /etc/systemd/system/
sudo cp systemd/photo-cloud-backup.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now photo-cloud-backup.timer
```

Teste uma execucao manual pelo systemd:

```bash
sudo systemctl start photo-cloud-backup.service
sudo journalctl -u photo-cloud-backup.service -n 100 --no-pager
```

## Git

O projeto foi pensado para versionamento:

- `.env` fica fora do Git
- `logs/` fica fora do Git
- `state/` fica fora do Git

## Nome recomendado para o repositorio

Sugestao principal:

- `photo-cloud-backup`

Alternativas:

- `onedrive-photo-archive`
- `gallery-offsite-backup`

## Revisao de privacidade

Os arquivos versionaveis foram mantidos sem:

- caminho real da sua pasta de origem
- nome real do remote do `rclone`
- estrutura real da pasta remota
- arquivos `.env`, logs ou estado de execucao

Se quiser publicar o projeto, revise apenas o `.git/config` local e confirme que nao existe `.env` no diretório antes do primeiro push.
