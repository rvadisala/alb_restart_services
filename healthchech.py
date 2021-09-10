#!/usr/bin/python3.6
import boto3
import pprint
region_name = "ap-south-1"
session = boto3.session.Session()
elb = session.client('elbv2')
ec2 = session.client('ec2')


def gettargetgroups(arn):
    tgs=elb.describe_target_groups(LoadBalancerArn=arn)
    tgstring=[]
    for tg in tgs["TargetGroups"]:
        tgstring.append(tg["TargetGroupName"])
    return tgstring

def gettargetgrouparns(arn):
    tgs=elb.describe_target_groups(LoadBalancerArn=arn)
    tgarns=[]
    for tg in tgs["TargetGroups"]:
        tgarns.append(tg["TargetGroupArn"])
    return tgarns

def getinstancename(instanceid):
    instances=ec2.describe_instances(Filters=[
        {
            'Name': 'instance-id',
            'Values': [
                instanceid
            ]
        },
    ],)
    for instance in instances["Reservations"]:
        for inst in instance["Instances"]:
            for tag in inst["Tags"]:
                if tag['Key'] == 'Name':
                    return (tag['Value'])


def gettargethealth(arn):
    inss=elb.describe_target_health(TargetGroupArn=arn)
    instanceids=[]
    for ins in inss["TargetHealthDescriptions"]:
        ins["Name"]=getinstancename(ins['Target']['Id'])
        instanceids.append(ins['Target']['Id'])
        print (ins)


# lbs = elb.describe_load_balancers(PageSize=400)
lbs = elb.describe_load_balancers(LoadBalancerArns=['arn:aws:elasticloadbalancing::loadbalancer/app/apache'])

print (lbs)

for lb in lbs["LoadBalancers"]:
    print("\n"*2)
    print ("-"*6)
    print("Name:",lb["LoadBalancerName"])
    print("Type:",lb["Type"])
    print("TargetGroups:",str(gettargetgroups(lb["LoadBalancerArn"])))

    for tgs in gettargetgrouparns(lb["LoadBalancerArn"]):
        gettargethealth(tgs)
