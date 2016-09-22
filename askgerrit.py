# USAGE: python askgerrit.py 2>/dev/null | wc -l 

#import os
#from requests.auth import HTTPDigestAuth
import requests
from pygerrit.rest import GerritRestAPI

from_time = "2016-09-16 16:40:00.000000"
match_word= 'revert'
token =     'xoxp-XXXXX-XXXXX' # change XXX to ABC, SLACK TOKEN =>  https://api.slack.com/docs/oauth-test-tokens

#auth = HTTPDigestAuth('username', 'password')
rest = GerritRestAPI(url='http://review.openstack.org')
changes = rest.get("/changes/?q=project:openstack/fuel-library branch:stable/mitaka")

for change in changes:
    if match_word in change['subject'].lower() and change['updated'] > from_time:
        ch = change['status'],change['updated'], change['subject']
        r = requests.get("https://slack.com/api/chat.postMessage?token="+token+"&channel=vmaliaev_notify&text=\
                         "+', '.join(ch)+"&pretty=1") #Send message to SLACK

        print change['status'],change['updated'], change['subject']

####

#os.system("curl -k 'https://slack.com/api/chat.postMessage?token=xoxp-XXXXXXXXXXXXXXXXXXXXXXXXXXX&channel=vmaliaev_notify&text=hello&pretty=1'")

#for header in r.headers:
#    print header,": ", r.headers[header]
