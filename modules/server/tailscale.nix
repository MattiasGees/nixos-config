# Tailscale — private access to polaris from outside the LAN (CGNAT rules out
# port-forwarding). Authenticate once after deploy: `sudo tailscale up`.
{ ... }:
{
  services.tailscale = {
    enable = true;
    # Open the UDP port so peers connect directly instead of via DERP relays.
    openFirewall = true;
  };
}
