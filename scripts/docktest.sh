#!/system/bin/sh
# Dock test recorder: kernel log + 1s state snapshots, survives adb disconnect.
# Run as root on the phone:
#   nohup setsid sh /data/local/tmp/docktest.sh >/dev/null 2>&1 </dev/null &
D=/data/local/tmp/docktest
mkdir -p $D
[ -f $D/kmsg.pid ] && kill $(cat $D/kmsg.pid) 2>/dev/null
cat /dev/kmsg > $D/kmsg.txt &
echo $! > $D/kmsg.pid
echo $$ > $D/loop.pid
while true; do
  up=$(cut -d' ' -f1 /proc/uptime)
  dr=$(cat /sys/class/typec/port0/data_role 2>/dev/null)
  pr=$(cat /sys/class/typec/port0/power_role 2>/dev/null)
  on=$(cat /sys/class/power_supply/usb/online 2>/dev/null)
  st=$(cat /sys/class/power_supply/battery/status 2>/dev/null)
  cur=$(cat /sys/class/power_supply/battery/current_now 2>/dev/null)
  usb=$(cat /sys/bus/usb/devices/*/product 2>/dev/null | tr '\n' '|')
  inp=$(grep -h '^N:' /proc/bus/input/devices 2>/dev/null | sed 's/N: Name=//' | tr '\n' ' ')
  rs=""; for d in usb1 1-1 1-1.2 usb2 2-1; do [ -e /sys/bus/usb/devices/$d/power/runtime_status ] && rs="$rs$d:$(cat /sys/bus/usb/devices/$d/power/runtime_status) "; done
  echo "$(date +%T) up=$up dr=[$dr] pr=[$pr] usb_online=$on bat=$st cur=$cur rpm=[$rs] usb=$usb inp=$inp" >> $D/state.txt
  sleep 1
done
