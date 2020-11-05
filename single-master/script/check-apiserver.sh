#!/bin/sh
errorExit() {
  echo "*** $*" 1>&2
  exit 1
}

curl --silent --max-time 2 --insecure https://localhost:6443/ -o /dev/null || errorExit "Error Get https://localhost:6443/"
if ip addr | grep -q 10.95.10.228; then
 curl --silent --max-time 2 --insecure https://10.95.10.228:6443/ -o /dev/null || errorExit "Error Get https://10.95.10.228:6443"
fi

#netstat -ntlp|grep 6443 || exit 1

