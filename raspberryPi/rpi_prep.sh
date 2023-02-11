#!/bin/bash
## pi
# setup ssh
cd ~ || exit
if [ ! -d .ssh ]; then
  mkdir .ssh
  chmod 700 .ssh
  touch .ssh/authorized_keys
fi

## root
# Set Timezone
sudo timedatectl set-timezone Australia/Sydney

# Set update repository and prepare base system
REPO=mirror.aarnet.edu.au
if ! grep -F -x -q $REPO  /etc/apt/sources.list; then
  sudo sed -i -e 's/raspbian.raspberrypi.org\/raspbian\//mirror.aarnet.edu.au\/pub\/raspbian\/raspbian\//g' /etc/apt/sources.list
  sudo apt-get purge -y vlc geany thonny qpdfview dillo gpicview cups git
  sudo apt-get autoremove -y
  sudo apt-get autoclean -y
  sudo apt update -y
  sudo apt upgrade -y
fi

# Enable VNC
sudo systemctl enable vncserver-x11-serviced.service
sudo systemctl start vncserver-x11-serviced.service

# Install file space manager
sudo apt install baobab -y

# Install rsync
sudo apt install rsync -y

# Setup SystemMaxUse for journald.conf
if ! grep -F -x -q /etc/systemd/journald.conf "#SystemMaxUse="; then
  sudo sed -i -e 's/#SystemMaxUse=/SystemMaxUse=32MB/g' /etc/systemd/journald.conf
fi

# Setup Log2ram
# https://github.com/azlux/log2ram
cd ~ || exit
mkdir tmp
cd tmp
wget https://github.com/azlux/log2ram/archive/master.tar.gz -O log2ram.tar.gz
tar xf log2ram.tar.gz
cd /home/pi/tmp/log2ram-master
sudo ./install.sh
cd ~
rm -rf tmp


## pi
# Setup autostart for the desktop
cd ~ || exit
cd .config || exit
mkdir -p lxsession/LXDE-pi
wget https://raw.githubusercontent.com/event-cell/scripts/main/raspberryPi/LXDE-pi.autostart --output-document=lxsession/LXDE-pi/autostart



