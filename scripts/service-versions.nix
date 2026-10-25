# What runs on a NixOS host and at which version, for scripts/flake-update.sh:
#
#   nix eval --impure --json .#nixosConfigurations.polaris --apply "$(cat scripts/service-versions.nix)"
#
# Every enabled services.<name> that has a `package` option, plus platform
# pieces that live outside services.* (kernel, NVIDIA, ZFS, Docker, Nix).
# Evaluation only, nothing is built. Returns
# { <name> = { version; changelog; } or { error = true; }; }.
system:
let
  inherit (system) config options;

  # Only look at services whose `enable` someone set. Renamed/removed options
  # (e.g. services.frp.enable) abort when their config value is read, and
  # tryEval can't catch abort; checking the option's definitions first never
  # reads that value.
  setServices = builtins.filter (name:
    let o = options.services.${name}; in
    builtins.isAttrs o && (o.enable._type or null) == "option" && o.enable.isDefined
  ) (builtins.attrNames options.services);

  info = p: { inherit (p) version; changelog = p.meta.changelog or null; };

  # A throw (e.g. a backport override's "no longer applies" tripwire) becomes
  # { error = true; } so the summary flags it instead of failing or hiding it.
  try = x: let r = builtins.tryEval (builtins.deepSeq x x); in if r.success then r.value else { error = true; };

  services = map (name: {
    inherit name;
    value = try (
      let c = config.services.${name}; in
      if c.enable == true && c ? package && c.package ? version then info c.package else null
    );
  }) setServices;

  platform = [
    { name = "linux"; value = try (info config.boot.kernelPackages.kernel); }
    { name = "nvidia"; value = try (if config.hardware.nvidia.enabled then info config.hardware.nvidia.package else null); }
    { name = "zfs"; value = try (if config.boot.zfs.enabled then info config.boot.zfs.package else null); }
    { name = "docker"; value = try (if config.virtualisation.docker.enable then info config.virtualisation.docker.package else null); }
    { name = "nix"; value = try (info config.nix.package); }
  ];
in
builtins.listToAttrs (builtins.filter (x: x.value != null) (services ++ platform))
