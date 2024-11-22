# smartMonitoring.sh
PoC smartctl wrapper for basic Home Assistant/mail notifications. Works by generating smart report for supported disks, checking status of self-assessment test and default parameters that for non-failing drives should always be zero (Reallocated_Sector_Ct Reallocated_Event_Count Current_Pending_Sector). For NVMe drives it only checks self-assessment and compares wear level against the defined threshold.
Additionally it reports motor state (spinning/not spinning) of HDDs and temperature of HDDs/SSDs/NVMes to HA. 
Smartctl is known to not work with some NVMe usb-pcie adapters but should work with most sata-usb bridges. If it doesn't - consider switching smartctl parameter "-d auto" to "-d sat" or any other available one.

Installation:

0. Install smartctl and curl
1. hardcode haAuthToken variable to long-lived HA token of any admin ha account (or use external provider script that outputs such token, ie. the default)
2. Adjust ha address and port, mail server ip address and port (it won't work with SSL in it's current state), hostname and other settings
3. Align ignored drive serial numbers and/or parameters if needed - some disks/bridges don't support SMART or just don't report any of the expected parameters
4. Consider automated execution by adding script to crontab. Personal settings:

1 0 * * * /bin/bash /usr/sbin/smartMonitoring.sh automated 2>&1 | /usr/bin/logger -t smartMonitoring

*/5 * * * * /bin/bash /usr/sbin/smartMonitoring.sh onlyspinning

Note: on some systems "onlyspinning" will spin up idling HDDs. Consider spindown settings of HDDs when modifying crontab. Above settings work fine after calling "/sbin/hdparm -S 50 /dev/sd?" as the spindown time is shorter than 5 minutes.

Note2: home assistant integration is done over rest api. Meaning any sensor that was created this way is going to disappear after HA restart. AFter being re-created they maintain previous history.

