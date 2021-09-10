#!/bin/bash

PIDFILE=/opt/sag/10.1/profiles/IS_default/bin/sagis101.pid
LOCKFILE=/var/lock/subsys/sagis101
CHDIR=/opt/sag/10.1/profiles/IS_default/bin/sagis101
SHUTDOWN_WAIT=60
RETVAL=0
TOMCAT_USER=saguser

# Source function library.
. /etc/rc.d/init.d/functions

start() {
    if [ -f $PIDFILE ]
    then
        RETVAL=1
        echo "$PIDFILE exists, process is already running or crashed" && failure
        echo
        return $RETVAL
    else
        echo "Staring tomcat service..."
        # $EXEC > /dev/null 2>&1 &
        systemctl start TanukiWrapper.service
        RETVAL=$?
        [ $RETVAL -eq 0 ] && touch $LOCKFILE && success || failure
        echo
        return $RETVAL
    fi
}

tomcat_pid() {
  echo `ps aux | grep -i '/opt/sag/10.1/profiles/IS_default/' | grep -v grep | awk '{print $2}' `
}



stop() {
    pid=$(tomcat_pid)
    if [ -n "$pid" ]
    then
        echo "Stopping Tomcat"
        systemctl stop TanukiWrapper.service 
	RETVAL=$?
	[ $RETVAL -eq 0 ]
	echo -n "."
	

 	while [ "$(ps -fu $TOMCAT_USER | grep java| grep -v grep | wc -l)" -gt "0" ]; do
        	sleep 5;
		cpid=$(ps -fu saguser | grep -i java | awk '{print $2}')
		kill -9 $cpid 2 > /dev/null ; rm -rf $LOCKFILE $PIDFILE
		echo -e -n "\n Tomcat has been killed manually"
    	done
    else
        echo "Tomcat is not running, its already stopped" && warning
    fi
    return $RETVAL
}

status() {
    systemctl status TanukiWrapper.service
    if curl --output /dev/null --silent --head --fail http://localhost:8080/
      then
        echo "Tomcat is now running"
      else
        echo "Tomcat could not be started"
    fi
}


case "$1" in
        start)
                start
                ;;
        stop)
                stop
                ;;
        restart)
                stop
                start
                ;;
  	status)
    		status
    		;;
        *)
                echo "Please use start, stop, status or restart as first argument"
                RETVAL=2
                ;;
esac

exit $RETVAL
