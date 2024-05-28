#!/bin/bash

function INFO() { echo -e "\e[0;32m${1}\e[0m"; }
function DONE() { echo -e "\e[0;34m[✓] Done! \e[0m\n"; }
function get_latest_version() {
    curl -sSL "https://api.github.com/repos/$1/releases" | jq -r '[.[] | select(.prerelease == false)][0].tag_name'
}

CILIUM_CLI_VERSION=$(curl -s https://raw.gitmirror.com/cilium/cilium-cli/main/stable.txt)
CILIUM_VERSION=$(get_latest_version "cilium/cilium")
CLI_ARCH=amd64

INFO "[*] CILIUM_CLI_VERSION $CILIUM_CLI_VERSION"
INFO "[*] CILIUM_VERSION $CILIUM_VERSION"
INFO "Press any key to continue ..."
read

INFO "[*] Install Cilium CLI"
curl -L --fail --remote-name-all https://gh.con.sh/https://github.com/cilium/cilium-cli/releases/download/${CILIUM_CLI_VERSION}/cilium-linux-${CLI_ARCH}.tar.gz{,.sha256sum}
sha256sum --check cilium-linux-${CLI_ARCH}.tar.gz.sha256sum
sudo tar xzvfC cilium-linux-${CLI_ARCH}.tar.gz /usr/local/bin
rm cilium-linux-${CLI_ARCH}.tar.gz{,.sha256sum}
DONE

INFO "[*] Install Cilium"
cilium install --version $(echo $CILIUM_VERSION | sed 's/v//g')
cilium status --wait
DONE
