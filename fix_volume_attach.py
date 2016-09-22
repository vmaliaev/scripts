#!/usr/bin/python -u
from neutronclient.v2_0 import client as neutron_client
from cinderclient import client as cinder_client
import novaclient.v1_1.client as nova_client
import os
import datetime
import netaddr
import subprocess
import sys
import argparse
import MySQLdb
 
### Input Args ###
parser = argparse.ArgumentParser(description='Supply Openstack credentials and log file name if needed')
parser.add_argument('-l', '--log-file', action="store", dest="logfile", help='Log file where to store statistics.')
parser.add_argument('-p', '--production-mode', action="store_true", help='If enabled script will make changes in Nova DB for cleaning up disappeared volumes.')
parser.add_argument('-A', '--OS_AUTH_URL', action="store", dest="auth_url", help='keystone auth url')
parser.add_argument('-T', '--OS_TENANT_NAME', action="store", dest="admin_project", help='project name where the authenticating user has the admin role.  This script will NOT work if this use does not have the admin role for this project.')
parser.add_argument('-U', '--OS_USERNAME', action="store", dest="admin_username", help='username to authenticate with to perform the administrator level actions required by this script.')
parser.add_argument('-P', '--OS_PASSWORD', action="store", dest="admin_password", help='password for the user specified by OS_USERNAME.')
parser.add_argument('-R', '--OS_REGION_NAME', action="store", dest="region", help='region specified by OS_REGION_NAME.')
parser.add_argument('-u', '--DB_NOVA_USER', action="store", dest="db_nova_user", help='Name of nova database user. Default value: nova.')
parser.add_argument('-H', '--DB_NOVA_HOST', action="store", dest="db_nova_host", help='Nova database host.')
parser.add_argument('-N', '--DB_NOVA_PASSWORD', action="store", dest="db_nova_pass", help='Nova database password.')
 
args = vars(parser.parse_args())
 
product_mode = args['production_mode']
 
auth_url = args['auth_url']
if auth_url == None:
    auth_url = os.environ.get('OS_AUTH_URL')
    if auth_url == None:
        print 'Error: you need to supply the --OS_AUTH_URL argument to this script, or define this environment variable'
        sys.exit(1)
 
admin_project = args['admin_project']
if admin_project == None:
    admin_project = os.environ.get('OS_TENANT_NAME')
    if admin_project == None:
        print 'Error: You need to supply the --OS_TENANT_NAME argument to this script, or define this environment variable'
        sys.exit(1)
 
admin_username = args['admin_username']
if admin_username == None:
    admin_username = os.environ.get('OS_USERNAME')
    if admin_username == None:
        print 'Error: You need to supply the --OS_USERNAME argument to this script, or define this environment variable'
        sys.exit(1)
 
admin_password = args['admin_password']
if admin_password == None:
    admin_password = os.environ.get('OS_PASSWORD')
    if admin_password == None:
        print 'Error: You need to supply the --OS_PASSWORD argument to this script, or define this environment variable'
        sys.exit(1)
 
region = args['region']
if region == None:
    region = os.environ.get('OS_REGION_NAME')
    if region == None:
        print 'Error: You need to supply the --OS_REGION_NAME argument to this script, or define this environment variable'
        sys.exit(1)
 
if product_mode:
    db_nova_pass = args['db_nova_pass']
    if db_nova_pass == None:
        db_nova_pass = os.environ.get('DB_NOVA_PASSWORD')
        if db_nova_pass == None:
            print 'Error: You need to supply the --DB_NOVA_PASSWORD argument to this script, or define this environment variable'
            sys.exit(1)
 
    db_nova_host = args['db_nova_host']
    if db_nova_host == None:
        db_nova_host = os.environ.get('DB_NOVA_HOST')
        if db_nova_host == None:
            print 'Error: You need to supply the --DB_NOVA_HOST argument to this script, or define this environment variable'
            sys.exit(1)
 
    db_nova_user = args['db_nova_user']
    if db_nova_user == None:
        db_nova_user = os.environ.get('DB_NOVA_USER')
        if db_nova_user == None:
            db_nova_user = 'nova'
 
log_name = args['logfile']
 
if log_name == None:
    log_name = os.environ.get('HOME') + "/fix_volume_attachments_" + datetime.datetime.now().strftime("%Y-%m-%d_%H-%M-%S") + ".log"
 
 
def get_credentials():
    d = {}
    d['username'] = admin_username
    d['password'] = admin_password
    d['auth_url'] = auth_url
    d['tenant_name'] = admin_project
    d['region_name'] = region
    return d
 
def get_nova_credentials():
    d = {}
    d['username'] = admin_username
    d['api_key'] = admin_password
    d['auth_url'] = auth_url
    d['project_id'] = admin_project
    d['region_name'] = region
    return d
 
def check_volumes(vm, vol_id_list, logfile, db=None):
 
    vm_id = getattr(vm, 'id')
    vm_volumes = getattr(vm, 'os-extended-volumes:volumes_attached')
    if vm_volumes:
        msg = "(NOVA) INFO: Instance: %s Attached volumes: %s\n" % (vm_id, vm_volumes)
        print msg,
        logfile.write(msg)
    else:
        msg = "(NOVA) OK: Instance %s is OK: NO attached volumes\n\n" % vm_id
        print msg,
        logfile.write(msg)
        return
 
    for curr_vol in vm_volumes:
        if curr_vol['id']:
            if curr_vol['id'] in vol_id_list:
                msg = "(CINDER) OK: Instance %s. Volume %s exists and is properly attached\n" % (vm_id, curr_vol['id'])
                print msg,
                logfile.write(msg)
                continue
            else:
                msg = "(CINDER) WARNING: Instance %s. Volume %s attached but doesn't really exist!\n" % (vm_id, curr_vol['id'])
                print msg,
                logfile.write(msg)
 
                # Production mode, if db_cursor not None
                if db:
                    msg = "INFO: Instance %s. Trying to fix DB entries for volume %s\n" % (vm_id, curr_vol['id'])
                    print msg,
                    logfile.write(msg)
                    sql = "select id from block_device_mapping where volume_id='%s' and instance_uuid='%s' and deleted='0'" % (curr_vol['id'], vm_id)
                    try:
                        db_cursor = db.cursor()
                        db_cursor.execute(sql)
                        results = db_cursor.fetchall()
                        for bdm_id in results:
                            sql2 = "update block_device_mapping set deleted='%d' where id='%d' and volume_id='%s' and instance_uuid='%s'" % (bdm_id[0], bdm_id[0], curr_vol['id'], vm_id)
                            try:
                                db_cursor.execute(sql2)
                                db.commit()
                            except:
                                db.rollback()
                                msg = "(MYSQL) CRITICAL: Instance %s. Volume %s: block_device_mapping table entry with id %d CANNOT be FIXED\n" % (vm_id, curr_vol['id'], bdm_id[0])
                                print msg,
                                logfile.write(msg)
                    except:
                        msg = "(MYSQL) CRITICAL: Instance %s. Volume %s CANNOT be FIXED: cannot get corresponding ids from DB\n" % (vm_id, curr_vol['id'])
                        print msg,
                        logfile.write(msg)
        else:
            msg = "(NOVA) CRITICAL: Nova client returned invalid data. Instance %s has attached volume with empty id!\n" % vm_id
            print msg,
            logfile.write(msg)
    print "\n",
    logfile.write("\n")
 
credentials_nova = get_nova_credentials()
nova = nova_client.Client(**credentials_nova)
cinder = cinder_client.Client('1', **credentials_nova)
 
 
server_list, volume_list  = None, None
 
server_list = nova.servers.list(search_opts = {'all_tenants': 1})
volume_list = cinder.volumes.list(search_opts = {'all_tenants': 1})
 
with open(log_name, "w") as logfile:
    if not server_list:
        msg = "(NOVA) ERROR: Cannot retreive list of instances. Connection to nova failed\n"
        print msg,
        logfile.write(msg)
        sys.exit(1)
    if not volume_list:
        msg = "(CINDER) ERROR: Cannot get list of cinder volumes. Connection to cinder failed\n"
        print msg,
        logfile.write(msg)
        sys.exit(1)
   
    # Extract cinder volume ids
    vol_ids = [v.id for v in volume_list]
 
    if not vol_ids:
        msg = "(CINDER) ERROR: Cinder volumes ids list is empty! Cinder API returned invalid data\n"
        print msg,
        logfile.write(msg)
        sys.exit(1)
 
    if product_mode:
        try:
            nova_db = MySQLdb.connect(db_nova_host, db_nova_user, db_nova_pass, "nova")
        except:
            msg = "(MYSQL) ERROR: Cannot connect to Nova MySQL database on host %s  as user %s\n\n\n" % (db_nova_host, db_nova_user)
            print msg,
            logfile.write(msg)
            sys.exit(1)
    else:
        nova_db = None
 
    instances_amount = str(len(server_list))
    msg = '>'*10 + 'Number of instances: ' + instances_amount + '<'*10 + "\n\n"
    print msg,
    logfile.write(msg)
    instance_counter = 0
    for vm in server_list:
        # Print progress on console
        instance_counter += 1
        head_msg = "%s Status: %s Compute host: %s " % (getattr(vm, 'id'), getattr(vm, 'status'), getattr(vm, 'OS-EXT-SRV-ATTR:host'))
        head_msg_stdout = "Instance %d from %s: " % (instance_counter, instances_amount) + head_msg
        head_msg_stdout_len = len(head_msg_stdout)
        msg_stdout = '='*head_msg_stdout_len + "\n" + head_msg_stdout + " \n" + '='*head_msg_stdout_len + "\n"
        print msg_stdout,
        # Don't print progress message to logfile (amount of instances and sequence can change)
        head_msg_logfile = "Instance: " + head_msg
        head_msg_logfile_len = len(head_msg_logfile)
        msg_logfile = '='*head_msg_logfile_len + "\n" + head_msg_logfile + " \n" + '='*head_msg_logfile_len + "\n"
        logfile.write(msg_logfile)
        check_volumes(vm, vol_ids, logfile, nova_db)
 
if product_mode:
    nova_db.close()
print "See log file here: %s" % log_name
