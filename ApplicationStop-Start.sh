#!/bin/bash

source $(dirname $0)/deregister_from_elb.sh ; source $(dirname $0)/tomcat-rollout.sh stop 


source $(dirname $0)/tomcat-rollout.sh start ; source $(dirname $0)/register_with_elb.sh && source $(dirname $0)/tomcat-rollout.sh status
