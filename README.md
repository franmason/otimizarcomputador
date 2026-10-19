# Otimizador de PC

App leve para Windows que faz só limpezas seguras, sem precisar de administrador:

- arquivos temporários do usuário e do Windows (com mais de 1 dia)
- cache do Chrome e do Edge (só caches de arquivos e de gráficos; pula o navegador se estiver aberto)
- relatórios de erro antigos do Windows e cache de gráficos (DirectX)
- cache de DNS
- diagnóstico do PC (somente leitura)
- teste de internet (download, upload, ping e oscilação, pelos servidores de teste da Cloudflare)
- atalho para os programas de inicialização do Gerenciador de Tarefas

Não mexe em registro, serviços, energia, senhas, histórico, cookies, favoritos ou arquivos pessoais,
nem em áudio/microfone ou nos dados do WhatsApp.
Os arquivos limpos vão para um backup e podem ser devolvidos com **Desfazer** (Ctrl+Z).

## Instalar

Baixe o `Instalar-Otimizador.exe` da [última Release](https://github.com/franmason/otimizarcomputador/releases/latest) e dê dois cliques.
O app é instalado só para o usuário atual, cria um ícone na Área de Trabalho e pode ser removido em
**Painel de Controle > Programas e Recursos**. Quando houver versão nova, aparece o botão **Atualizar** no app.

## Lançar uma versão nova

1. Altere o código e aumente `$script:Versao` no `Otimizador.ps1`.
2. Escreva o que mudou no [NOVIDADES.md](NOVIDADES.md), numa seção `## <versão>`.
3. `.\Gerar-EXE.ps1`
4. `git commit` e `git push`
5. `.\Publicar-Atualizacao.ps1`

As novidades aparecem para o cliente antes de atualizar, depois de atualizar e na página de Releases.

Tudo é feito em PowerShell; o [PS2EXE](https://github.com/MScholtes/PS2EXE) empacota o script em `.exe`.
