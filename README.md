# Otimizador de PC

App leve para Windows que faz só limpezas seguras, sem precisar de administrador:

- arquivos temporários do usuário e do Windows (com mais de 1 dia)
- cache do Chrome e do Edge (só Cache, Code Cache e GPUCache; pula o navegador se estiver aberto)
- cache de DNS
- diagnóstico do PC (somente leitura)
- atalho para os programas de inicialização do Gerenciador de Tarefas

Não mexe em registro, serviços, energia, senhas, histórico, cookies, favoritos ou arquivos pessoais.
Os arquivos limpos vão para um backup e podem ser devolvidos com **Desfazer** (Ctrl+Z).

## Instalar

Baixe o `Instalar-Otimizador.exe` da [última Release](https://github.com/franmason/otimizarcomputador/releases/latest) e dê dois cliques.
O app é instalado só para o usuário atual, cria um ícone na Área de Trabalho e pode ser removido em
**Painel de Controle > Programas e Recursos**. Quando houver versão nova, aparece o botão **Atualizar** no app.

## Lançar uma versão nova

1. Altere o código e aumente `$script:Versao` no `Otimizador.ps1`.
2. `.\Gerar-EXE.ps1 -Novidades "O que mudou"`
3. `git commit` e `git push`
4. `.\Publicar-Atualizacao.ps1`

Tudo é feito em PowerShell; o [PS2EXE](https://github.com/MScholtes/PS2EXE) empacota o script em `.exe`.
