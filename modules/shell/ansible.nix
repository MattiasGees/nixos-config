# Ansible CLI plus speed-ups for every run.
# Set as environment variables rather than ~/.ansible.cfg: Ansible reads only
# the first config file it finds, so a project's ./ansible.cfg would hide a
# home one, while ANSIBLE_* variables apply on top of whichever file is used.
# SSH multiplexing needs nothing here: Ansible's default ssh_args already use
# ControlMaster/ControlPersist.
{ config, pkgs, ... }:

{
  home.packages = [ pkgs.ansible ];

  home.sessionVariables = {
    # Send modules over the open SSH session instead of copying a temp file
    # per task. Needs sudoers without `requiretty` (the Debian default).
    ANSIBLE_PIPELINING = "True";

    # Gather facts once per host per run (not once per play), and keep them
    # for an hour across runs. `ansible-playbook --flush-cache` refreshes.
    ANSIBLE_GATHERING = "smart";
    ANSIBLE_CACHE_PLUGIN = "jsonfile";
    ANSIBLE_CACHE_PLUGIN_CONNECTION = "${config.xdg.cacheHome}/ansible/facts";
    ANSIBLE_CACHE_PLUGIN_TIMEOUT = "3600";

    # Per-task timings and the slowest tasks at the end of a run.
    ANSIBLE_CALLBACKS_ENABLED = "ansible.posix.profile_tasks";
  };
}
