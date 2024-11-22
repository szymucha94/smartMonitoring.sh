#!/bin/bash
hostname="$(hostname)"
haAddressAndPort="192.168.57.2:8123"
readonly haAuthToken=$(/usr/sbin/get_ha_token.sh)
if [ -z $haAuthToken ]; then
  echo "HA token unavailable. Exiting!"
  exit 1
fi

expectedDisks="sda sdb sdc sdd sde"
syslogTemp="/dev/shm/.syslog_uas_io_errors"
disksLost=null

while true
do

  devDisks="$(ls /dev | grep sd[a-f]$ | tr '\n' ' ' | rev | cut -c2- | rev)"

  grep "$(date +"%d")T" /var/log/syslog | grep sd[a-f] | grep -i "i/o error" > $syslogTemp

  if [[ "$devDisks" != "$expectedDisks" ]]; then
    disksLost="$expectedDisks"

    for del in ${devDisks[@]}
    do
       echo $del
       disksLost=("${disksLost[@]/$del}")
       echo "$disksLost"
    done

    disksLost="$(echo $disksLost | sed 's/^[ \t]*//;s/[ \t]*$//')"
  fi

  for disk in ${expectedDisks[@]}
  do
    errorCnt=$(grep $disk $syslogTemp | wc -l)
    /usr/bin/curl -s -o /dev/null -X POST -H "Authorization: Bearer $haAuthToken" -H "Content-Type: application/json" -d '{"state": "'"$errorCnt"'", "attributes": {"friendly_name": "'"${hostname} ${disk}"' HDD I/O Error Counter", "state_class": "total"}}' http://$haAddressAndPort/api/states/sensor.${hostname}hddioerrors_${disk}
    if [[ $(echo $disksLost | grep $disk) ]]; then
      /usr/bin/curl -s -o /dev/null -X POST -H "Authorization: Bearer $haAuthToken" -H "Content-Type: application/json" -d '{"state": "OFFLINE", "attributes": {"friendly_name": "'"${hostname} ${disk}"' HDD Online Status"}}' http://$haAddressAndPort/api/states/sensor.${hostname}hddonlinestatus_${disk}
    else
      /usr/bin/curl -s -o /dev/null -X POST -H "Authorization: Bearer $haAuthToken" -H "Content-Type: application/json" -d '{"state": "ONLINE", "attributes": {"friendly_name": "'"${hostname} ${disk}"' HDD Online Status"}}' http://$haAddressAndPort/api/states/sensor.${hostname}hddonlinestatus_${disk}
    fi
  done

  rm -rf $syslogTemp
  disksLost=null
  sleep 120
done
