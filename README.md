Developed by Visal Weerakoon | 2026
Tested Device: Dialog ZLT S12 Pro 4G CPE

This modification was developed and tested on a Dialog ZLT S12 Pro router. Compatibility with other versions and variants has not been verified.
⚠️ WARNING: USE AT YOUR OWN RISK ⚠️

This project involves modifying router firmware and system configurations. Incorrect firmware installation or script execution may cause device malfunction, configuration loss, or permanent damage (bricking).

You are entirely responsible for any risks associated with using these files and scripts. Only proceed if you understand the risks and have permission to modify the router.

Always keep a backup of your original firmware before proceeding.
Download the provided firmware file:

S12_4.32.3.1_1.35.1_telnet_enable.bin

1. Log in to your Tozed S12 router's web administration interface.
2. Navigate to the Firmware Upgrade section.
3. Select S12_4.32.3.1_1.35.1_telnet_enable.bin.
4. Start the firmware update.
5. Wait until the router completes the update and reboots.

Important: Do not disconnect the router or interrupt the firmware update process.
After the firmware update is completed, connect your computer to the router's LAN network.

Open a Telnet client and connect to the router:
```
telnet 192.168.8.1 23
```
Log in using the credentials configured on your router.

username = root
pw = password is empty [press enter]

All commands in the following steps must be executed directly inside the router's CLI (Telnet terminal), not in Windows CMD or PowerShell.
After copying enable_telnet_dropbear.sh to the router, navigate to the directory containing the script and run it with root privileges:
```
sh enable_telnet_dropbear.sh
```
This script performs the main Telnet and SSH configuration. It configures the Telnet service, restores Dropbear SSH where available, configures the login accounts, enables automatic service startup, and checks the service status.
If duplicate characters appear while typing commands in the Telnet terminal, run the following script:
```
sh fix_telnet_double_echo.sh
```
This script modifies the Telnet configuration to prevent duplicate character echoing. Reconnect your Telnet session after applying the fix.
To check the current Telnet and SSH service status, run:
```
sh enable_telnet_dropbear.sh status
```
To stop and disable both services, run:
```
sh enable_telnet_dropbear.sh disable
```
Note: The disable command stops the services and resets their configuration flags. It does not necessarily restore every original system setting or password.

Item	Details
Device	Tozed S12 UNISOC PLUS 4G CPE
Tested Router	Dialog ZLT S12 Pro 4G CPE
Firmware File	S12_4.32.3.1_1.35.1_telnet_enable.bin
Firmware Version	4.32.3.1
Build Version	1.35.1
Platform	UNISOC
Architecture	mipsel_24kc
OS	OpenWrt based firmware


⚠️ Telnet is an unencrypted protocol. The supplied scripts configure empty password accounts by default. This is highly insecure.
- Do not expose Telnet or SSH to the public internet.
- Keep WAN access disabled.
- Change empty passwords to strong passwords.
- Use SSH with key based authentication wherever possible.
This project is provided for educational, research, and authorized router administration purposes.

The developer does not guarantee compatibility with other router models or firmware versions. Use the supplied firmware and scripts at your own risk.

The developer is not responsible for bricked devices, hardware damage, data loss, or other issues resulting from firmware installation or script execution.
Visal Weerakoon
- Portfolio: https://visalweerakoon.com
- GitHub: https://github.com/visalweerakoon
Developed by Visal Weerakoon | 2026