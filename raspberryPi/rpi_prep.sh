#!/bin/bash
# pi - setup ssh
cd ~ || exit
mkdir .ssh
chmod 700 .ssh
touch .ssh/authorized_keys

# root
sudo sed -i -e 's/raspbian.raspberrypi.org\/raspbian\//mirror.aarnet.edu.au\/pub\/raspbian\/raspbian\//g' /etc/apt/sources.list
sudo apt update -y
sudo apt upgrade -y

sudo systemctl enable vncserver-x11-serviced.service
sudo systemctl start vncserver-x11-serviced.service

# pi
cd
mkdir .config
cd .config
mkdir -p lxsession/LXDE-pi
wget --ftp-user=anonymous ftp://192.168.11.15/pi/sdma/LXDE-pi.autostart --output-document=lxsession/LXDE-pi/autostart
