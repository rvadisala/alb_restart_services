#!/bin/bash
#
# The elements in TARGET_LIST should be seperated by space.
TARGET_GROUP_LIST="apache-tgt-test"

# PORT defines which port the application is running at.
# If PORT is not specified, the script will use the default port set in target groups
PORT="8080"

############################################################################################################
#  You shouldn't change anything below this line uder any circumstances, If need any modifications	   #
#													   #
#             Please reach out ravi.vadisala@netenrich.com, cloudops@netenrich.com			   #
############################################################################################################

export PATH="$PATH:/usr/bin:/usr/local/bin"

# If true, all messages will be printed. If false, only fatal errors are printed.
DEBUG=true

# Number of times to check for a resouce to be in the desired state.
WAITER_ATTEMPTS=60

# Number of seconds to wait between attempts for resource to be in a state for ALB registration/deregistration.
WAITER_INTERVAL_ALB=10

# Usage: get_instance_region
get_instance_region() {
    if [ -z "$AWS_REGION" ]; then
        AWS_REGION=$(curl -s http://169.254.169.254/latest/dynamic/instance-identity/document | grep -i region | awk -F\" '{print $4}')
    fi

    echo $AWS_REGION
}

AWS_CLI="aws --region $(get_instance_region)"

# reset_waiter_timeout <target group name> <state name>
#    When waiting for instance goes into "healthy" state, using health check trheshold * (health_check_timeout + healthy_check_interval) to compute timeout for health check
#    When waiting for instance goes into "unused" state, using deregistration timeout as timeout for health check
reset_waiter_timeout() {
    local target_group_name=$1
    local state_name=$2

    if [ "$state_name" == "healthy" ]; then
        msg "Getting target group health check configuration for target group $target_group_name"
        local target_group_info=$($AWS_CLI elbv2 describe-target-groups --names $target_group_name --query 'TargetGroups[*].[HealthCheckIntervalSeconds,HealthCheckTimeoutSeconds,HealthyThresholdCount]' --output text)

        if [ $? != 0 ]; then
            msg "Couldn't describe target group named '$target_group_name'"
            return 1
        fi

        msg "Calculating timeout for register instance in target group $target_group_name"
        local health_check_interval=$(echo $target_group_info | awk '{print $1}')
        local health_check_timeout=$(echo $target_group_info | awk '{print $2}')
        local health_check_threshold=$(echo $target_group_info | awk '{print $3}')
        local timeout=$(echo "$health_check_threshold * ( $health_check_timeout + $health_check_interval )" | /usr/bin/bc)
    elif [ "$state_name" == "unused" ]; then
        msg "Getting target group arn for target group $target_group_name"
        local target_group_arn=$($AWS_CLI elbv2 describe-target-groups --names $target_group --query 'TargetGroups[*].[TargetGroupArn]' --output text)

        msg "Getting instance deregistration delay timeout for target group $target_group with target group arn $target_group_arn"
        local timeout=$($AWS_CLI elbv2 describe-target-group-attributes --target-group-arn $target_group_arn --query "Attributes[?Key=='deregistration_delay.timeout_seconds'].Value[]" --output text)
    else
        msg "Unknown state name, '$state_name'";
        return 1;
    fi

    # Base register/deregister action may take up to about 30 seconds
    timeout=$((timeout + 60))
    msg "The current wait time out is set to $timeout second(s)"
    WAITER_ATTEMPTS=$((timeout / WAITER_INTERVAL_ALB))
}

# Waits for the state of <EC2 instance ID> to be in <state> as seen by <service>. Returns 0 if 
# it successfully made it to that state; non-zero if not. By default, checks $WAITER_ATTEMPTS
wait_for_state() {
    local service=$1
    local instance_id=$2
    local state_name=$3
    local target_group=$4
    local waiter_attempts=$5

    local instance_state_cmd
    if [ "$service" == "alb" ]; then
        instance_state_cmd="get_instance_health_target_group $instance_id $target_group"
        reset_waiter_timeout $target_group $state_name
        if [ $? != 0 ]; then
            error_exit "Failed re-setting waiter timeout for $target_group"
        fi
        local waiter_interval=$WAITER_INTERVAL_ALB
    else
        msg "Cannot wait for instance state; unknown service type, '$service'"
        return 1
    fi

    # Check if a custom waiter_attempts was passed into the function
    # and override the attemps if true
    if [ -z "$waiter_attempts" ]; then
        local waiter_attempts=$WAITER_ATTEMPTS
    fi

    msg "Checking $waiter_attempts times, every $waiter_interval seconds, for instance $instance_id to be in state $state_name"

    local instance_state=$($instance_state_cmd)
    local count=1

    msg "Instance is currently in state: $instance_state"
    while [ $instance_state != $state_name ]; do
        if [ $count -ge $waiter_attempts ]; then
            local timeout=$(($waiter_attempts * $waiter_interval))
            msg "Instance failed to reach state, $state_name within $timeout seconds"
            return 1
        fi

        sleep $waiter_interval

        instance_state=$($instance_state_cmd)
        count=$(($count + 1))
        msg "Instance is currently in state: $instance_state"
    done

    return 0
}

# get_instance_health_target_group <EC2 instance ID> <target group>
get_instance_health_target_group() {
    local instance_id=$1
    local target_group=$2

    msg "Checking status of instance '$instance_id' in target group '$target_group'"

    msg "Getting target group arn and port for target group '$target_group'"

    local target_group_info=$($AWS_CLI elbv2 describe-target-groups --names $target_group --query 'TargetGroups[*].[TargetGroupArn,Port]' --output text)

    if [ $? != 0 ]; then
        msg "Couldn't describe target group named '$target_group_name'"
        return 1
    fi

    local target_group_arn=$(echo $target_group_info | awk '{print $1}')
    if test -z "$PORT"; then
        local target_group_port=$(echo $target_group_info | awk '{print $2}')
    else
        local target_group_port=$PORT
    fi

    msg "Checking instance health state for instance '$instance_id' in target group '$target_group' against port '$target_group_port'"

    local instance_status=$($AWS_CLI elbv2 describe-target-health --target-group-arn $target_group_arn --targets Id=$instance_id,Port=$target_group_port \
        --query 'TargetHealthDescriptions[*].TargetHealth[].State' --output text 2>/dev/null)

    if [ $? == 0 ]; then
        case "$instance_status" in
             initial|healthy|unhealthy|unused|draining)
                echo -n $instance_status
                return 0
                ;;
            *)
                msg "Couldn't retrieve instance health status for instance '$instance_id' in target group '$target_group'"
                return 1
        esac
    fi
}

# Deregisters <EC2 instance ID> from <target group name>.
deregister_instance() {
    local instance_id=$1
    local target_group_name=$2

    msg "Checking validity of target group named '$target_group_name'"
    local target_group_arn=$($AWS_CLI elbv2 describe-target-groups --names $target_group_name --query 'TargetGroups[*].[TargetGroupArn]' --output text)

    if [ $? != 0 ]; then
        msg "Couldn't describe target group named '$target_group_name'"
        return 1
    fi

    msg "Found target group arn $target_group_arn for target group $target_group"
    msg "Deregistering $instance_id from $target_group using target group arn $target_group_arn"

    if test -z "$PORT"; then
        $AWS_CLI elbv2 deregister-targets --target-group-arn $target_group_arn --targets Id=$instance_id 1> /dev/null
    else
      $AWS_CLI elbv2 deregister-targets --target-group-arn $target_group_arn --targets Id=$instance_id,Port=$PORT 1> /dev/null
    fi
    return $?
}

# Registers <EC2 instance ID> to <target group name>.
register_instance() {
    local instance_id=$1
    local target_group_name=$2

    msg "Checking validity of target group named '$target_group_name'"

    local target_group_info=$($AWS_CLI elbv2 describe-target-groups --names $target_group_name --query 'TargetGroups[*].[TargetGroupArn,Port]' --output text)

    if [ $? != 0 ]; then
        msg "Couldn't describe target group named '$target_group_name'"
        return 1
    fi

    local target_group_arn=$(echo $target_group_info | awk '{print $1}')
    if test -z "$PORT"; then
        local target_group_port=$(echo $target_group_info | awk '{print $2}')
    else
        local target_group_port=$PORT
    fi

    msg "Registering instance instance '$instance_id' to target group '$target_group_name' against port '$target_group_port'"
    $AWS_CLI elbv2 register-targets --target-group-arn $target_group_arn --targets Id=$instance_id,Port=$target_group_port 1> /dev/null

    return $?
}

# Usage: check_cli_version [version-to-check] [desired version]
check_cli_version() {
    if [ -z $1 ]; then
        version=$($AWS_CLI --version 2>&1 | cut -f1 -d' ' | cut -f2 -d/)
    else
        version=$1
    fi

    if [ -z "$2" ]; then
        min_version=$MIN_CLI_VERSION
    else
        min_version=$2
    fi

    x=$(echo $version | cut -f1 -d.)
    y=$(echo $version | cut -f2 -d.)
    z=$(echo $version | cut -f3 -d.)

    min_x=$(echo $min_version | cut -f1 -d.)
    min_y=$(echo $min_version | cut -f2 -d.)
    min_z=$(echo $min_version | cut -f3 -d.)

    msg "Checking minimum required CLI version (${min_version}) against installed version ($version)"

    if [ $x -lt $min_x ]; then
        return 1
    elif [ $y -lt $min_y ]; then
        return 1
    elif [ $y -gt $min_y ]; then
        return 0
    elif [ $z -ge $min_z ]; then
        return 0
    else
        return 1
    fi
}

# Usage: msg <message>
msg() {
    local message=$1
    $DEBUG && echo $message 1>&2 && echo
}

# Usage: error_exit <message>
error_exit() {
    local message=$1

    echo "[FATAL] $message" 1>&2
    exit 1
}

# Usage: get_instance_id
get_instance_id() {
    curl -s http://169.254.169.254/latest/meta-data/instance-id
    return $?
}
