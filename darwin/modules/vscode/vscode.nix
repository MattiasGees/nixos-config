{ lib, pkgs, ... }:

let
  # Visual Studio Code user settings managed declaratively.
  # VSCode itself is installed via a Homebrew cask; settings.json is rendered
  # read-only, while extensions are declared here but kept MUTABLE - they are
  # seeded through VSCode's own CLI so VSCode keeps owning updates/removals.
  settings = (pkgs.formats.json { }).generate "vscode-settings.json" {
    "editor.tabSize" = 2;
    "files.insertFinalNewline" = true;
    "files.trimFinalNewlines" = true;
    "gitlens.keymap" = "alternate";
    "gitlens.advanced.messages" = {
      suppressCommitHasNoPreviousCommitWarning = false;
      suppressCommitNotFoundWarning = false;
      suppressFileNotUnderSourceControlWarning = false;
      suppressGitVersionWarning = false;
      suppressLineUncommittedWarning = false;
      suppressNoRepositoryWarning = false;
      suppressResultsExplorerNotice = false;
      suppressShowKeyBindingsNotice = true;
    };
    "gitlens.historyExplorer.enabled" = true;
    "go.autocompleteUnimportedPackages" = true;
    "latex-workshop.view.pdf.viewer" = "browser";
    "redhat.telemetry.enabled" = false;
    "[python]" = {
      "editor.formatOnType" = true;
    };
    "go.toolsManagement.autoUpdate" = true;
    "workbench.editorAssociations" = {
      "*.pdf" = "default";
    };
    "github.copilot.nextEditSuggestions.enabled" = true;
    "docker.extension.enableComposeLanguageServer" = false;
    "yaml.disableSchemaDetection" = [
      "**/.github/workflows/*.yml"
      "**/.github/workflows/*.yaml"
      "**/.gitea/workflows/*.yml"
      "**/.gitea/workflows/*.yaml"
      "**/.forgejo/workflows/*.yml"
      "**/.forgejo/workflows/*.yaml"
    ];
    "update.showReleaseNotes" = false;
  };

  # Extensions to ensure are present on a fresh machine. They are installed via
  # VSCode's CLI (not pinned by Nix), so VSCode continues to update them.
  extensions = [
    "adpyke.codesnap"
    "bierner.markdown-mermaid"
    "davidanson.vscode-markdownlint"
    "docker.docker"
    "eamodio.gitlens"
    "elijah-potter.harper"
    "github.codespaces"
    "github.vscode-github-actions"
    "golang.go"
    "hashicorp.terraform"
    "james-yu.latex-workshop"
    "jnoortheen.nix-ide"
    "ms-azuretools.vscode-containers"
    "ms-azuretools.vscode-docker"
    "ms-kubernetes-tools.vscode-kubernetes-tools"
    "ms-python.debugpy"
    "ms-python.python"
    "ms-python.vscode-pylance"
    "ms-python.vscode-python-envs"
    "ms-vscode-remote.remote-containers"
    "ms-vscode.makefile-tools"
    "pomdtr.excalidraw-editor"
    "redhat.vscode-yaml"
    "streetsidesoftware.code-spell-checker"
    "streetsidesoftware.code-spell-checker-british-english"
    "technosophos.vscode-helm"
    "timonwong.shellcheck"
  ];

  # `code` CLI shipped by the Homebrew cask.
  code = "/opt/homebrew/bin/code";
in

{
  home.file."Library/Application Support/Code/User/settings.json".source = settings;

  # Seed any missing extensions through VSCode itself. Idempotent and
  # non-fatal: skips already-installed ones and never blocks activation
  # (e.g. offline, or before the cask is installed).
  home.activation.vscodeExtensions = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    if [ -x "${code}" ]; then
      installed="$("${code}" --list-extensions 2>/dev/null || true)"
      for ext in ${lib.escapeShellArgs extensions}; do
        if ! printf '%s\n' "$installed" | grep -qixF "$ext"; then
          run "${code}" --install-extension "$ext" || true
        fi
      done
    fi
  '';
}
