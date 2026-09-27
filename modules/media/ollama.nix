# Ollama — local LLM inference on the RTX 3080 (driver from nvidia.nix).
# Verify offload with `nvidia-smi` showing an `ollama` process during a prompt.
#
# ⚠️ GPU support is selected by the package variant (pkgs.ollama-cuda); the old
# `services.ollama.acceleration = "cuda"` option was removed upstream. (CUDA is
# unfree — covered by the flake-wide allowUnfree.)
#
# Listens on 127.0.0.1:11434 (default), no firewall hole and no Caddy vhost;
# its only client is Open WebUI (open-webui.nix).
#
# Storage: models are large but re-downloadable, so they live on the
# unredundant, un-backed-up `scratch` pool (modelsDir defaults to
# /srv/scratch/ollama/models).
#
# Static user/group instead of the default DynamicUser: a transient UID would
# leave the persistent models dir unwritable. Setting BOTH makes the module
# create the system user/group with home = /srv/scratch/ollama.
{ pkgs, ... }:
{
  services.ollama = {
    enable = true;
    package = pkgs.ollama-cuda;
    user = "ollama";
    group = "ollama";
    home = "/srv/scratch/ollama";
    # Pre-pulled on startup. Qwen3 8B (~5 GB at Q4) fits the 3080's VRAM with
    # headroom and has a toggleable thinking mode (/think, /no_think).
    loadModels = [ "qwen3:8b" ];
  };

  # The module grants ReadWritePaths but doesn't create the dir. tmpfiles runs
  # after local-fs.target, so this lands on the mounted scratch pool.
  systemd.tmpfiles.rules = [
    "d /srv/scratch/ollama 0700 ollama ollama - -"
  ];

  # Never start before scratch is mounted, so models can't silently land in the
  # empty underlying dir on the root disk.
  systemd.services.ollama.unitConfig.RequiresMountsFor = "/srv/scratch";
}
