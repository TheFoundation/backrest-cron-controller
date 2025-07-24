# backrest-cron-controller
backrest API cron job cronfroller that sends statistics to influxdb, runs automatic index repairs and writes status percentage to stdout to use it with cronicle
# backrest-cron-controller
backrest API cron job cronfroller that 
  * sends statistics to influxdb, 
  * runs automated "repair index" command on repository if previous cancelled or failed backups detected
  * writes status percentage to stdout to use it with cronicle

## Features

* designed to run in cronicle
* will detect if another version of the script was killed and keep sending stats for the other one but exit with status 1 



## Installation and Usage
 * install the thingy by running git clone or mount it into e.g. a cronicle docker container
 * run it after setting the variables via export, example for cronicle shell plugin:
   ```
   #/bin/sh
   which git &>/dev/null || apk add git
   test -e /opt/backrest-cron-controller &&  (cd /opt/backrest-cron-controller;git pull )
   test -e /opt/backrest-cron-controller ||  git clone https://github.com/TheFoundation/backrest-cron-controller.git /opt/backrest-cron-controller
   export AUTH="backrest_username:backrest_pass" 
   export DOMAIN=backrest-ssl.domain.lan
   export HEALTHCHECKSIO=https://hc-ping.com/123-abc-321-cde
   export PLAN=daily-backup
   export INFLUX_TOKEN=A5Da5df00f00b49b49A5Da5df00b49==
   export INFLUX_URL="https://westeurope-over-9000.outage365-azure.cloud2.influxdata.com/api/v2/write?org=f33db33f&bucket=BACKUPRESTIC&precision=ns"
   /bin/bash /opt/backrest-cron-controller/run-backrest-backup.sh || exit 1
    ```

## backrest API Examples 

For anyone having a hard time since the backrest webpage does not show you how to run commonds etc.:

```
#curl -kLv -X POST  -u "backrest_username:backrest_pass" https://backrest.domain.lan/v1.Backrest/Backup --data '{"value":"daily-projects"}' -H 'Content-Type: application/json'

#curl -kLv -X POST  -u "backrest_username:backrest_pass" https://backrest.domain.lan/v1.Backrest/RunCommand --data '{"repoId": "s3-work","command": "repair index"}' -H 'Content-Type: application/json'

#curl -kL -X POST  -s -u "backrest_username:backrest_pass" 'https://backrest.domain.lan/v1.Backrest/GetOperations' --data '{"selector": {"RepoId": "s3-work"}}' -H 'Content-Type: application/json'|jq -c .operations[]|grep '"repoId":"'s3-work'",'|grep INPROGR|jq -c .operationBackup.lastStatus.status

#curl -kL -X POST  -s -u "backrest_username:backrest_pass" 'https://backrest.domain.lan/v1.Backrest/GetOperations' --data '{"selector": {"planId": "daily-docker-homes"}}' -H 'Content-Type: application/json'|jq -c .operations[]|grep '"planId":"'daily-docker-homes|grep INPR


#curl -kL -X POST  -s -u "backrest_username:backrest_pass" 'https://backrest.domain.lan/v1.Backrest/DoRepoTask'  --data '{"repoId": "s3-work","task": "TASK_STATS"}' -H 'Content-Type: application/json'
#   TASK_INDEX_SNAPSHOTS TASK_CHECK  TASK_PRUNE     TASK_STATS     TASK_UNLOCK

```

<h3>A project of the foundation</h3>
<a href="https://the-foundation.gitlab.io/"><div><img src="https://hcxi2.2ix.ch/github/TheFoundation/backrest-cron-controller/README.md/logo.jpg" width="480" height="270"/></div></a>

