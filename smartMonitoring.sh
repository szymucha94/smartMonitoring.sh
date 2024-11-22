#!/bin/bash

lockFile="/dev/shm/.smartMonitoring_lock"
smartOutput="/dev/shm/.smartMonitoringOutput.tmp"
lockNotificationsFile="/dev/shm/.smartMonitoringLockNotificationsfile"
sendMailNoOfRetries="5"

#--
#list of ignored parameters for defined drive serial numbers
#serial number can be obtained by using command: lsblk /dev/sd<letter> -n -o serial -d
#make sure to keep the format of new entries
#Example:
#IDP#AAAAAAAAAAAAB#Some_Parameter_Name#Another_Parameter_Name#

#IDP#C01120111107000009D8#Reallocated_Event_Count#
#IDP#201010151BC9#Reallocated_Event_Count#Current_Pending_Sector#
#IDP#CVCV3153047M180EGN#Reallocated_Event_Count#Current_Pending_Sector#
#IDP#17DJCADST#Reallocated_Sector_Ct#Reallocated_Event_Count#
#IDP#A46207060A8901571057#Reallocated_Sector_Ct#Reallocated_Event_Count#Current_Pending_Sector#
#IDP#EI4CN09991030CS39#Reallocated_Sector_Ct#Reallocated_Event_Count#Current_Pending_Sector#
#--

#--
#list of ignored drive serial numbers
#make sure to keep the format of new entires
#Example:
#ISN#AAAAAAAAAAAAB#
#ISN#2HC015KJ#
#ISN#012345679029#
#ISN#191443803707#
#ISN#4C531001571026103404#
#--

#settings
defaultListOfSmartParamsToCheck=(Reallocated_Sector_Ct Reallocated_Event_Count Current_Pending_Sector)
listOfIgnoredDisksOnSpindownTest=()
hostname="$(hostname)"
nvmeWearWarningThreshold="30"
reportDiskTempToHA=true
reportDiskStateToHA=true
reportDiskSmartStateToHa=true

#settingsForAutomatedMode
sendMailNotification=yes
sendMailServer="192.168.1.194"
sendMailPort="25"
sendMailSender="notifier@$(hostname)"
sendMailRecipient="szymucha@19net.pl"
haNotificationEnabled="true"
haAddressAndPort="192.168.57.2:8123"
readonly haAuthToken=$(/usr/sbin/get_ha_token.sh)
if [ -z $haAuthToken ]; then
  echo "HA token unavailable. Disabling HA integrations."
  HA_TOKEN_AVAILABLE="false"
else
  HA_TOKEN_AVAILABLE="true"
fi

printHelp() {
    echo ""
    echo "smartctl wrapper for HA/mail notifications."
    echo "Usage: $0 <option> [/dev disk names]"
    echo "Local functions:"
    echo "  -a | --all                   Takes no arguments. Checks all SATA/NVMe drives present in /dev"
    echo "  -d | --disks                 Requires at least one /dev SATA/NVMe drive name. Checks specified drive(s)."
    echo "  onlyspinning                 Takes no arguments. Checks all spinning SATA and all NVMe drives present in /dev and notifies"
    echo "  automated                    Takes no arguments. Checks all SATA drives present in /dev and notifies"
    echo "  -h | --help                  Prints this help"
    echo "Example: $0 -d sda sdb sdc"
}

initialChecks() {
#lock check
if [ -f $lockFile ]; then
  echo "Another instance already running, exiting..."
  exit
fi

#lock
touch $lockFile
if [ $? -ne 0 ]; then
  echo "Script error: failed to create lock file. $lockFile not writable?"
  exit
else
  :
fi

#initial checks
if [[ $(whoami) != "root" ]]; then
  echo "Script error: insufficient permissions to start. Root permissions required."
  #unlock
  rm $lockFile
  exit
fi

if [[ -f /usr/sbin/smartctl ]]; then
  smartctlBinary="/usr/sbin/smartctl"
else
  if ! [[ $(command -v smartctl) ]]; then
    echo "Script error: smartctl binary is not available using \$PATH variable. Exiting..."
    #unlock
    rm $lockFile
    exit
  else
  smartctlBinary="smartctl"
  fi
fi
  noOfDisks=$(ls /dev | grep -e "sd.$\|nvme.n1$" | wc -l)
  listOfAllDisks=$(ls /dev | grep -e "sd.$\|nvme.n1$")
}

reportDiskStateIfAllowed() {
  if [[ $HA_TOKEN_AVAILABLE="true" && $reportDiskStateToHA == "true" && $(echo $1 | grep -v nvme) ]]; then
    curl -s -o /dev/null -X POST -H "Authorization: Bearer $haAuthToken" -H "Content-Type: application/json" -d '{"state": "'"$2"'", "attributes": {"friendly_name": "'"$hostname $1"' HDD State"}}' http://$haAddressAndPort/api/states/sensor.${hostname}HDDState_$1
  fi
}

reportDiskSmartStateIfAllowed() {
  if [[ $HA_TOKEN_AVAILABLE="true" && $reportDiskSmartStateToHa == "true" ]]; then
    curl -s -o /dev/null -X POST -H "Authorization: Bearer $haAuthToken" -H "Content-Type: application/json" -d '{"state": "'"$2"'", "attributes": {"friendly_name": "'"$hostname $1"' HDD SMART State"}}' http://$haAddressAndPort/api/states/sensor.${hostname}HDDSmartState_$1
  fi
}

addSpinningDisksToList() {

  local disk=1
  listOfSpinningDisks=""
  noOfSpinningDisks=0

  while [ $disk -le $noOfDisks ]; do
    if ! [[ $(echo $listOfIgnoredDisksOnSpindownTest | grep $1) ]]; then
      timeout --kill-after=10s 5s $smartctlBinary -n standby /dev/$1 > /dev/null 2>&1
      standbyTestCode=$?
      case $standbyTestCode in
        0)
          listOfSpinningDisks="$listOfSpinningDisks $1"
          shift
          ((noOfSpinningDisks++))
          ((disk++))
        ;;
        2)
          reportDiskStateIfAllowed $1 Standby
          shift
          ((disk++))
        ;;
        *)
          reportDiskStateIfAllowed $1 Error
          shift
          ((disk++))
        ;;
      esac
    else
      shift
      ((disk++))
    fi
  done
  if [[ $noOfSpinningDisks -eq "0" ]]; then
    echo "No active disks. Exiting..."
    cleanup
    unlock
    exit
  else
    noOfDisks=$noOfSpinningDisks
  fi
}

checkDisksForSmartSupport() {

  listOfSmartCapableDisks=""
  local disk=1
  echo "Collecting S.M.A.R.T. reports..."
  while [ $disk -le $noOfDisks ]; do
    if (ls /dev | grep -e "^sd\|^nvme" | grep ^$1$ > /dev/null); then
      if [ $(grep "^#ISN#$(lsblk /dev/$1 -n -o serial -d)#$" $0) ]; then
        shift
        ((disk++))
      else
        timeout --kill-after=35s 30 $smartctlBinary -d auto -a /dev/$1 > /dev/shm/.smartctl_$1.tmp
        if [[ $(grep -ie "SMART support is: Available\|NVMe Log 0x02" /dev/shm/.smartctl_$1.tmp) ]]; then
          listOfSmartCapableDisks="$listOfSmartCapableDisks $1"
          ((disk++))
          shift
        else
          reportDiskSmartStateIfAllowed $1 ERR
          echo "[NOK] /dev/$1: S.M.A.R.T. is not supported or disk didn't respond. Ignoring..." | tee -a $smartOutput
          shift
          ((disk++))
        fi
      fi
    else
      echo "[NOK] /dev/$1: Disk doesn't exist"
      shift
      ((disk++))
    fi
  done
}

reportDiskTempIfAllowed() {
  if [[ $reportDiskTempToHA == "true" ]]; then
    if [[ $(echo $1 | grep sd) ]]; then
      hdtemperature=$(grep "^194" /dev/shm/.smartctl_$1.tmp | grep -i Temperature_Celsius | awk '{ print $10 }')
    fi
    if [[ $(echo $1 | grep nvme) ]]; then
      hdtemperature=$(grep -i "Temperature Sensor 1" /dev/shm/.smartctl_$1.tmp | awk '{ print $4 }')
    fi
    if [[ -n "$hdtemperature" ]] && [[ "$hdtemperature" -eq "$hdtemperature" ]] && [[ $HA_TOKEN_AVAILABLE="true" ]]; then
      curl -s -o /dev/null -X POST -H "Authorization: Bearer $haAuthToken" -H "Content-Type: application/json" -d '{"state": "'"$hdtemperature"'", "attributes": {"friendly_name": "'"$hostname $1"' HDD Temperature", "unit_of_measurement": "°C", "device_class": "temperature"}}' http://$haAddressAndPort/api/states/sensor.${hostname}HDDTemperature_$1
    fi
  fi
}

checkDisksForSmartStatus() {

  local smartDisk=0
  local smartParam=0
  local noOfArgs=$#

  while [[ $smartDisk -lt $noOfArgs && -f /dev/shm/.smartctl_$1.tmp ]]; do
    name=$(grep -ie "Device Model\|Model Number" /dev/shm/.smartctl_$1.tmp | sed 's/Device Model:\|Model Number\://g' | sed 's/ //g')
    reportDiskTempIfAllowed $1
    reportDiskStateIfAllowed $1 Running
    haState=OK
    while [ $smartParam -lt ${#defaultListOfSmartParamsToCheck[@]} ]; do
      output=$(grep -i ${defaultListOfSmartParamsToCheck[$smartParam]} /dev/shm/.smartctl_$1.tmp | tr -s ' ' | rev |  cut -d " " -f 1 | rev)
      if [[ $(grep "^#IDP#$(lsblk /dev/$1 -n -o serial -d)#" $0 | grep -i "#${defaultListOfSmartParamsToCheck[$smartParam]}#") || $(echo $1 | grep nvme) ]]; then
        :
      else
        if [[ "$output" -eq "0" && ! -z "$output" ]]; then
          echo "[OK] Disk $1 $name: parameter \"${defaultListOfSmartParamsToCheck[$smartParam]}\" raw value: \"$output\""
        else
          haState=NOK
          if [[ "$output" -ge "0" && ! -z "$output" ]]; then
            echo "[NOK] Disk $1 $name: parameter \"${defaultListOfSmartParamsToCheck[$smartParam]}\" raw value: \"$output\""
          else
            if [[ -z "$output" ]]; then
              echo "[WARNING] Disk $1 $name: unsupported parameter \"${defaultListOfSmartParamsToCheck[$smartParam]}\""
            else
              echo "[WARNING] Disk $1 $name: unrecognized raw value of \"${defaultListOfSmartParamsToCheck[$smartParam]}\": \"$output\""
            fi
          fi
        fi
      fi
    ((smartParam++))
    done
    if [[ $(echo $1 | grep nvme) ]]; then
      local nvmeWear="$(grep "Percentage Used" /dev/shm/.smartctl_$1.tmp | awk '{ print $3 }' | sed 's/[^0-9]*//g')"
      if [[ $nvmeWear -lt $nvmeWearWarningThreshold ]]; then
        echo "[OK] Disk $1 $name: Wear level ($nvmeWear %) below warning threshold ($nvmeWearWarningThreshold %)"
      else
        echo "[NOK] Disk $1 $name: Wear level ($nvmeWear %) above warning threshold ($nvmeWearWarningThreshold %)"
        haState=NOK
      fi
    fi
    if [[ $(grep -i "self-assessment test result" /dev/shm/.smartctl_$1.tmp | grep -i "passed") && -f /dev/shm/.smartctl_$1.tmp ]]; then
      :
    else
      haState=NOK
      echo "[NOK] Disk $1 $name: self-assessment test failed. Failed attributes:"
      echo "$(grep FAILING_NOW /dev/shm/.smartctl_$1.tmp)"
    fi
    reportDiskSmartStateIfAllowed $1 $haState
    ((smartDisk++))
    #reset counter for another drive
    local smartParam=0
    shift
  done
  #nasty cleanup
  rm /dev/shm/.smartctl*.tmp >/dev/null 2>&1
}

lockMailNotificationsIfExceeded() {
  if [[ -f $lockNotificationsFile ]]; then
    sendMailNotification=no
  fi
  if [[ $(grep "NOK\|WARNING" $smartOutput) ]]; then
    touch $lockNotificationsFile
  fi
}

removeLockMailNotifications() {
  if [[ -f $lockNotificationsFile ]]; then
    rm $lockNotificationsFile
  fi
}

sendMailNotificationIfFailure() {
  if [[ $(grep "NOK\|WARNING" $smartOutput) && $sendMailNotification == "yes" ]]; then
    sendMail > /dev/null 2>&1
    sendHAWarningNotification
  fi
}

sendMail() {
  v=0
  while [[ $v -le $sendMailNoOfRetries ]]; do
      exec 5<>/dev/tcp/$sendMailServer/$sendMailPort
      if [[ $? -ne 0 ]]; then
        echo "sendmail(): Failed to open file descriptor. Retrying" 1>&0
        ((v++))
        if [[ $v -eq $sendMailNoOfRetries ]]; then
          echo "sendmail(): Exceeded number of retries. Giving up" 1>&0
          removeLockMailNotifications
          break
        fi
        sleep 5
      else
        echo -e "HELO" >&5
        echo -e "MAIL FROM: $sendMailSender" >&5
        echo -e "RCPT TO: $sendMailRecipient" >&5
        echo -e "DATA" >&5
        echo -e "SUBJECT: S.M.A.R.T. failure at $(hostname)" >&5
        echo -e "$(cat $smartOutput)" >&5
        echo -e "." >&5
        timeout 1 cat <&5
        exec 5>&-
        echo "sendmail(): Mail notification has been successfully sent to $sendMailRecipient" 1>&0
        break
      fi
  done
}

sendHAWarningNotification() {
  if [[ "$haNotificationEnabled" == "true" && $HA_TOKEN_AVAILABLE="true" ]]; then
    curl -s -o /dev/null -X POST -H "Authorization: Bearer $haAuthToken" -H "Content-Type: application/json" -d '{"state": '1', "attributes": {"friendly_name": "'"$hostname"' S.M.A.R.T. Alert Indication"}}' http://$haAddressAndPort/api/states/sensor.${hostname}SmartSystemAlert
  fi
}

cleanup() {
  if [[ -f $smartOutput ]]; then
    rm $smartOutput
  fi
}

unlock() {
  rm $lockFile
}

if [ $# -lt 1 ]
  then
    echo "Script error: missing argument"
    printHelp
  else
    argument="$1"
    case $argument in
      -a|--all|all)
        initialChecks
        checkDisksForSmartSupport $listOfAllDisks
        checkDisksForSmartStatus $listOfSmartCapableDisks
        removeLockMailNotifications
        cleanup
        unlock
        ;;
      -d|--disks|disks)
        initialChecks
        shift
        noOfDisks=$#
        checkDisksForSmartSupport $@
        checkDisksForSmartStatus $listOfSmartCapableDisks
        removeLockMailNotifications
        cleanup
        unlock
        ;;
      onlyspinning)
        initialChecks
        shift
        addSpinningDisksToList $listOfAllDisks
        checkDisksForSmartSupport $listOfSpinningDisks
        checkDisksForSmartStatus $listOfSmartCapableDisks | tee -a $smartOutput
        lockMailNotificationsIfExceeded
        sendMailNotificationIfFailure
        cleanup
        unlock
        ;;
      automated)
        initialChecks
        checkDisksForSmartSupport $listOfAllDisks
        checkDisksForSmartStatus $listOfSmartCapableDisks | tee -a $smartOutput
        sendMailNotificationIfFailure
        removeLockMailNotifications
        cleanup
        unlock
        ;;
      -h|--help|help)
        printHelp
        ;;
      *)
        echo "Script error: unrecognized argument"
        ;;
    esac
fi
