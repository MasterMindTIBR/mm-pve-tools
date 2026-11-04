# Resumo de evidência do laboratório

Os logs brutos ficam fora do repositório, no diretório configurado por
`LAB_EVIDENCE_DIR`. O repositório recebe somente o resumo gerado por
`t/lab/run-all.sh`.

Cada resumo deve conter apenas uma linha por etapa com `PASS` ou `FAIL` e as
versões instaladas dos pacotes. Não incluir topologia, endereços, nomes de
host, nomes de cliente, tokens, senhas, URLs autenticadas, UPIDs, hashes de
arquivos ou cópia de logs.

Formato mínimo:

```markdown
# Evidência Rock 7 — resumo sanitizado

Gerado em UTC: <timestamp>

| Etapa | Resultado | Versões dos pacotes |
|---|---|---|
| deploy | PASS | mm-pve-tools <versão>; mm-gw-restore <versão> |
```
