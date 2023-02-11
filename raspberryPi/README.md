# Raspberry Pi Imaging
Download the [Raspberry Pi Imager](https://www.raspberrypi.com/software/)

Use the Raspberry Pi OS (32-bit) Desktop Image
- Select the "Gear" icon and
    - Set the hostname
    - Enable SSH
    - Set the password for the `pi` user
    - Set the SSID and password for the WiFi
- Image
- Boot whilst connected to a monitor (important to allow the desktop to setup correctly)

Once booted SSH into the device and download the [installation script](https://raw.githubusercontent.com/event-cell/scripts/main/raspberryPi/rpi_prep.sh)

`wget https://raw.githubusercontent.com/event-cell/scripts/main/raspberryPi/rpi_prep.sh`

`chmod 755 rpi_prep.sh`






