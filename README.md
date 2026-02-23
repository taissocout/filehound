```md
# FileHound — OSINT File Finder + Metadata Report (ExifTool) + HTML

> **Propósito:** localizar **arquivos públicos** expostos em um domínio (e, opcionalmente, hosts descobertos por DNS/AXFR), baixar com validação, extrair metadados com **ExifTool** e gerar um **relatório HTML** clicável (`file://`).

⚠️ **Uso responsável / autorização**  
Esta ferramenta é destinada a **testes autorizados** (pentest, auditoria interna, bug bounty com escopo permitido). Não use em alvos sem permissão explícita.

---

## ✨ O que a ferramenta faz

Dependendo do modo selecionado, o FileHound pode:

1. **Encontrar URLs** de arquivos públicos no domínio alvo usando dorks do tipo:
   - `site:TARGET ext:pdf`, `site:TARGET ext:docx`, etc.
2. **Baixar arquivos** encontrados com checagens de segurança:
   - valida `Content-Type`, limita tamanho (`--max-mb`), evita baixar HTML “disfarçado”.
3. **Extrair metadados** com `exiftool`:
   - Autor, empresa, software gerador, datas, IDs, etc.
4. **Gerar relatório HTML** completo e abrir via navegador com link `file://`.
5. *(Opcional)* **DNS discovery / AXFR**:
   - tenta obter hosts via tentativa de transferência de zona (se permitido e disponível).

---

## 📦 Estrutura de saída (output)

Ao executar, ele cria uma pasta como:

```

filehound_example.com_20260223_162447/
├── raw/           # HTML/dumps retornados pelos buscadores (e fallback)
├── urls/          # listas por extensão e lista consolidada all_urls.txt
├── downloads/     # arquivos baixados
├── metadata/      # exiftool (.txt e .json) por arquivo
└── report/        # REPORT.html + mapas e listas auxiliares

````

Arquivos importantes:
- `urls/all_urls.txt` — **todas as URLs únicas**
- `report/downloaded_files.txt` — caminhos dos arquivos baixados
- `report/download_map.tsv` — mapeia `URL -> arquivo salvo`
- `report/<seu_nome>.html` — relatório final

---

## ✅ Requisitos

### Dependências
- `curl`
- `exiftool`
- `file`
- `sha256sum` (vem no coreutils)
- `dig` (dnsutils)
- `python3`

### (Opcional, recomendado para fallback quando buscadores bloqueiam)
- `lynx` **ou**
- `wget`

---

## 🛠️ Instalação (Kali/Debian/Ubuntu)

```bash
sudo apt update
sudo apt install -y curl exiftool file coreutils dnsutils python3
# opcionais:
sudo apt install -y lynx wget
````

Baixe/clone e prepare o script:

```bash
git clone git@github.com:taissocout/filehound.git
cd filehound
chmod +x filehound.sh
```

Teste de sintaxe (boa prática):

```bash
bash -n filehound.sh
```

---

## 🚀 Uso rápido (recomendado)

### 1) Full automático (mais comum)

Ele pede apenas **target** e **nome do relatório** (sem `.html`).

```bash
./filehound.sh -t example.com --report-name relatorio
```

No final, ele imprime algo assim:

* `[LINK] file:///.../report/relatorio.html`
* comando `xdg-open "/.../relatorio.html"`

---

## 📌 Ajuda (tutorial no terminal)

```bash
./filehound.sh -h
# ou
./filehound.sh --help
```

---

## ⚙️ Modos de execução

O `--mode` define até onde a ferramenta vai:

### `urls` (somente coleta)

* **não baixa**
* **não gera HTML**
* gera `urls/all_urls.txt`

```bash
./filehound.sh -t example.com --report-name lista --mode urls
```

### `download` (coleta + baixa)

* baixa arquivos válidos
* **não extrai exif**
* **não gera HTML**

```bash
./filehound.sh -t example.com --report-name run1 --mode download
```

### `full` (coleta + baixa + exif + HTML) ✅ recomendado

```bash
./filehound.sh -t example.com --report-name relatorio --mode full
```

---

## 🔎 Engines (buscadores)

Por padrão: `all`
Você pode limitar para reduzir tempo/ruído:

```bash
./filehound.sh -t example.com --report-name relatorio -e brave,bing
```

Opções:

* `brave,bing,ddg,yandex,ecosia,qwant,swisscows,mojeek,all`

---

## 🧾 Tipos de arquivo (filetypes)

Por padrão o FileHound pesquisa vários formatos comuns:

`pdf,doc,docx,xls,xlsx,ppt,pptx,txt,csv,json,xml,zip,rar,7z,sql,log`

Para limitar:

```bash
./filehound.sh -t example.com --report-name relatorio -f pdf
```

Vários tipos:

```bash
./filehound.sh -t example.com --report-name relatorio -f "pdf,docx,xlsx"
```

---

## 🧱 Controle de tamanho (anti-surpresa)

Limite de download por arquivo (default `50MB`):

```bash
./filehound.sh -t example.com --report-name relatorio --max-mb 15
```

---

## 🕒 Timing seguro (reduzir ruído/bloqueio)

O FileHound aplica delays/jitter entre requests.

Ajuste:

```bash
./filehound.sh -t example.com --report-name relatorio \
  --delay-ms 1600 --jitter-ms 1200 \
  --download-delay-ms 1400 --download-jitter-ms 1200
```

---

## 🧬 User-Agent (UA) — rotação automática

Por padrão: `--ua-mode rotate`
Ou seja, a cada request ele escolhe um UA conhecido aleatório.

### Fixar um UA

```bash
./filehound.sh -t example.com --report-name relatorio \
  --ua-mode fixed --ua "FileHound/1.9.1 (Authorized security test)"
```

### UA por fase (search vs download)

```bash
./filehound.sh -t example.com --report-name relatorio --ua-mode phase
```

### Lista customizada de UAs (arquivo)

Crie `uas.txt`:

```txt
Mozilla/5.0 (...) Chrome/122...
Mozilla/5.0 (...) Firefox/123...
```

E rode:

```bash
./filehound.sh -t example.com --report-name relatorio --ua-file uas.txt
```

---

## 🧰 Fallback (quando buscadores bloqueiam HTML)

Alguns buscadores limitam scraping. O FileHound pode tentar:

* `lynx --dump` (melhor para extrair links)
* `wget -qO-` (fallback extra)

Controle com:

```bash
./filehound.sh -t example.com --report-name relatorio --fetch-fallback auto
```

Opções:

* `auto` (padrão)
* `on` (força tentar se existir)
* `off` (desliga)

---

## 🌐 DNS Discovery / AXFR (opcional e sensível)

> Só ative se você **tem autorização** para testar infraestrutura DNS.

Ativar:

```bash
./filehound.sh -t example.com --report-name relatorio --dns on
```

Ele tenta:

* descobrir nameservers (`dig NS`)
* tentar AXFR (transferência de zona) dentro de limites:

  * `--axfr-retries`
  * `--axfr-timeout`
  * `--axfr-backoff`
  * `--max-hosts`

Exemplo com limites mais conservadores:

```bash
./filehound.sh -t example.com --report-name relatorio --dns on \
  --axfr-retries 2 --axfr-timeout 4 --axfr-backoff "3,8" --max-hosts 80
```

Saída:

* `report/hosts.txt`
* `report/sites.txt` (target + hosts)

Se `hosts.txt` ficar vazio: **normal** (AXFR geralmente é bloqueado).

---

## 🧪 Exemplo de workflow de pentest profissional (OSINT → evidência)

1. Recon rápido (sem baixar):

```bash
./filehound.sh -t example.com --report-name lista --mode urls
```

2. Coleta completa com evidência (HTML):

```bash
./filehound.sh -t example.com --report-name report_example --mode full \
  -e brave,bing --max-mb 20 \
  --delay-ms 1800 --jitter-ms 1200 \
  --download-delay-ms 1500 --download-jitter-ms 1000
```

3. Abrir relatório:

```bash
xdg-open "$(pwd)/filehound_example.com_*/report/report_example.html"
```

---

## 🔍 O que procurar nos metadados (rápido e prático)

No relatório (seção “Metadata Analysis”), foque em:

* **Author / Last Modified By**
* **Company / Department / Manager**
* **Creator Tool / Producer / Software**
* **Create/Modify Date**
* **Document ID / Instance ID**
* pistas de **paths internos**:

  * `C:\Users\...`
  * `/home/...`
  * `\\server\share`

Isso costuma revelar:

* nomes de usuários internos
* nomes de máquinas/hosts
* stack de software de geração de documentos
* padrões de naming de departamentos/áreas

---

## 🧯 Troubleshooting

### “0 URLs found”

* tente engines diferentes:

  ```bash
  ./filehound.sh -t example.com --report-name relatorio -e brave,bing
  ```
* aumente fallback:

  ```bash
  sudo apt install -y lynx
  ./filehound.sh -t example.com --report-name relatorio --fetch-fallback on
  ```

### “baixou HTML e removeu”

* normal: o script descarta arquivos que o `file` identifica como HTML.

### erros de sintaxe

* valide:

  ```bash
  bash -n filehound.sh
  ```

---

## 🧾 Créditos

Criado por **Taissocout**

* GitHub: [https://github.com/taissocout](https://github.com/taissocout)
* LinkedIn: [https://www.linkedin.com/in/taissocout_cybersecurity/](https://www.linkedin.com/in/taissocout_cybersecurity/)

---

## 📄 Licença

Defina a licença do projeto (ex: MIT) em `LICENSE`.

```
```

