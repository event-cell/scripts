# Raspberry Pi Imaging
Download the [Raspberry Pi Imager](https://www.raspberrypi.com/software/)

Use the Raspberry Pi OS (32-bit) Desktop Image
- Select the "Gear" icon and
    - Set the hostname
    - Enable SSH
    - Set the password for the `pi` user
    - Set the SSID and password for the WiFi
    - Set WiFi locale
    - Set Locale
- Image
- Boot whilst connected to a monitor (important to allow the desktop to setup correctly)

# Raspberry Pi Prep Script

This repository includes a Raspberry Pi preparation script that configures a base system and applies common settings.

## Bootstrap (one-liner)

Run this on the Raspberry Pi (as user `pi`) and provide a **mandatory hostname**:

```bash
curl -fsSL https://raw.githubusercontent.com/event-cell/scripts/refs/heads/main/raspberryPi/rpi_prep.sh | bash -s -- <hostname>
