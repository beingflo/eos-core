#!/usr/bin/env bash
#
# Reference: bringing up the firewall on a Fedora Asahi Remix homeserver.
# NOT meant to be run unattended — work through it step by step, on a console
# or with a second SSH session open. Verify after each section.
#
# Stack: firewalld (nftables backend) + rootless podman + caddy + wireguard.
#
# Why firewalld: the filtering needed here is a handful of ports plus one
# trusted interface, which is exactly what zones express. netavark also
# integrates with it automatically, so container networking needs no
# hand-written rules.

set -euo pipefail

### 0. Before you start #######################################################
#
# Have a way back in that does not depend on the network:
#   • a physical console (keyboard + screen), or
#   • a second SSH session that stays open the whole time.
#
# firewalld makes this less dangerous than raw nftables: rules added WITHOUT
# --permanent live only in the running config, so a reboot undoes a mistake.
# Test with runtime rules, promote to --permanent once verified.

uname -a
cat /etc/os-release


### 1. Install packages ######################################################

sudo dnf install -y firewalld podman caddy wireguard-tools

# firewalld is usually preinstalled on Fedora Asahi Remix; the install is a
# no-op then. Do NOT also enable the `nftables` service — two managers on the
# same hooks is how you get rules that mysteriously stop working.
systemctl is-enabled nftables 2>/dev/null && \
    echo "WARNING: nftables.service is enabled, disable it" || true

sudo systemctl enable --now firewalld
firewall-cmd --state                    # expect: running


### 2. Inspect the defaults ##################################################
#
# Fedora ships the `FedoraServer`/`public` zone with ssh + dhcpv6-client
# already allowed, so you are not starting from nothing.

firewall-cmd --get-default-zone
firewall-cmd --list-all                 # what is open right now
firewall-cmd --get-active-zones


### 3. Public services #######################################################
#
# Caddy on 80/443 and the WireGuard endpoint. Everything else stays closed.
# Runtime first (no --permanent), so a reboot rescues you.

sudo firewall-cmd --add-service=http
sudo firewall-cmd --add-service=https
sudo firewall-cmd --add-port=51820/udp  # must equal ListenPort in wg0.conf

# SSH: already open via the default zone's `ssh` service. Confirm rather than
# assume — this is the rule you cannot afford to get wrong.
firewall-cmd --query-service=ssh        # expect: yes

# Verify from ANOTHER machine before making any of this permanent:
#   ssh you@server                      -> succeeds
#   nc -zv server 443                   -> succeeds once Caddy runs
#   nc -zv server 8080                  -> times out
#
# A *timeout* means the packet was dropped. "Connection refused" means the
# firewall passed it and nothing was listening — a very different result.

firewall-cmd --list-all

# Happy? Persist by repeating with --permanent, then reload.
sudo firewall-cmd --permanent --add-service=http
sudo firewall-cmd --permanent --add-service=https
sudo firewall-cmd --permanent --add-port=51820/udp
sudo firewall-cmd --reload

# `--runtime-to-permanent` also works, but it promotes EVERYTHING currently in
# the runtime config, including anything netavark or you added ad hoc. Being
# explicit is worth the extra typing.


### 4. Reboot test ###########################################################
#
# Do this now, while you still have console access.

# sudo reboot
firewall-cmd --list-all                 # after reboot: 80/443/51820 still there


### 5. Podman (rootless) #####################################################
#
# Rootless is the right default here, and specifically avoids a firewalld
# footgun: with ROOTFUL podman, `-p` punches through the firewall
# automatically, so a published port is internet-visible regardless of your
# zone config. (firewalld 2.3.0+ can block this with StrictForwardPorts=yes,
# but that breaks -p entirely for rootful.)
#
# Rootless + loopback publishing sidesteps it: traffic to 127.0.0.1 never
# traverses the firewall, so there is nothing to configure and nothing to
# leak. Caddy stays the only way in.

# As your normal user, NOT root:
systemctl --user enable --now podman.socket
loginctl enable-linger "$USER"          # keep services running after logout

# Quadlets live in ~/.config/containers/systemd/ (rootless).
# After editing a .container file:
#   systemctl --user daemon-reload && systemctl --user start <name>
#
# Bind every service to loopback in the quadlet:
#   PublishPort=127.0.0.1:8080:8080
#
# SELinux is enforcing: bind-mounted volumes need :Z (private) or :z (shared),
#   Volume=/srv/app/data:/data:Z
# otherwise the container gets EACCES on paths that look world-readable.

# No firewall rules for containers. For the record, if you ever go ROOTFUL:
#   • netavark adds podman subnets to the `trusted` zone by itself
#   • but `firewall-cmd --reload` wipes netavark's rules — running containers
#     lose networking until you run:
#         sudo netavark firewall-reload      # netavark >= 1.17
#         sudo podman network reload --all   # older
#   Rootless is unaffected by reloads.


### 6. Caddy #################################################################

sudo systemctl enable --now caddy

# Let SELinux allow Caddy to reach the loopback-published containers:
sudo setsebool -P httpd_can_network_connect 1

# Ports 80/443 must be forwarded on the router for ACME to issue certs.
sudo journalctl -u caddy -f              # watch the first cert issuance


### 7. WireGuard #############################################################

# /etc/wireguard/wg0.conf — ListenPort must equal the port opened in §3.
# Set MTU = 1420 in the [Interface] section. This is the reason no MSS
# clamping is needed: clamping exists to fix MTU mismatches over the tunnel,
# and firewalld cannot express it.
sudo chmod 600 /etc/wireguard/wg0.conf
sudo systemctl enable --now wg-quick@wg0

sudo wg show                             # peers, handshakes
ip -br addr show wg0

# Put wg0 in the `trusted` zone: peers can reach anything, which is the whole
# point of the VPN. This replaces the `iifname "wg0" accept` rule.
sudo firewall-cmd --permanent --zone=trusted --add-interface=wg0
sudo firewall-cmd --reload
firewall-cmd --zone=trusted --list-all

# Only if peers route LAN/internet traffic THROUGH this host (VPN exit):
#   sudo firewall-cmd --permanent --zone=trusted --add-masquerade
#   echo 'net.ipv4.ip_forward=1' | sudo tee /etc/sysctl.d/99-forward.conf
#   echo 'net.ipv6.conf.all.forwarding=1' | sudo tee -a /etc/sysctl.d/99-forward.conf
#   sudo sysctl --system
# Not needed just to reach services on this box.

# Re-verify from a peer, THEN close public SSH:
#   sudo firewall-cmd --permanent --remove-service=ssh
#   sudo firewall-cmd --reload
# wg0 being trusted keeps SSH reachable over the VPN. Test it in a second
# session first — you are removing your own way in, and if WireGuard is
# misconfigured you will need the console.


### 8. Ongoing ###############################################################

firewall-cmd --list-all-zones            # full picture, all zones
firewall-cmd --get-active-zones          # which interface is in which zone

# Log denied packets (off by default):
sudo firewall-cmd --set-log-denied=unicast
sudo journalctl -k -f | grep -i reject

# Inspect the generated nftables rules when a zone does not behave:
sudo nft list ruleset | less
