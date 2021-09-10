#!/bin/bash
#

. $(dirname $0)/common_functions.sh

msg "Running AWS CLI with region: $(get_instance_region)"

# get this instance's ID
INSTANCE_ID=$(get_instance_id)
if [ $? != 0 -o -z "$INSTANCE_ID" ]; then
    error_exit "Unable to get this instance's ID; cannot continue."
fi

# Get current time
msg "Started $(basename $0) at $(/bin/date "+%F %T")"
start_sec=$(/bin/date +%s.%N)

msg "Checking that user set at least one valid target group"
if test -z "$TARGET_GROUP_LIST"; then
    error_exit "Must have at least one target group to deregister from"
fi

msg "Checking whether the port number has been set"
if test -n "$PORT"; then
    if ! [[ $PORT =~ ^[0-9]+$ ]] ; then
       error_exit "$PORT is not a valid port number"
    fi
    msg "Found port $PORT, it will be used for instance health check against target groups"
else
    msg "PORT variable is not set, will use the default port number set in target groups"
fi

# Loop through all target groups the user set, and attempt to deregister this instance from them.
for target_group in $TARGET_GROUP_LIST; do
    msg "Deregistering $INSTANCE_ID from $target_group starts"
    deregister_instance $INSTANCE_ID $target_group

    if [ $? != 0 ]; then
        error_exit "Failed to deregister instance $INSTANCE_ID from target group $target_group"
    fi
done

# Wait for all Deregistrations to finish
msg "Waiting for instance to de-register from its target groups"
for target_group in $TARGET_GROUP_LIST; do
    wait_for_state "alb" $INSTANCE_ID "unused" $target_group
    if [ $? != 0 ]; then
        error_exit "Failed waiting for $INSTANCE_ID to leave $target_group"
    fi
done


msg "Finished $(basename $0) at $(/bin/date "+%F %T")"
