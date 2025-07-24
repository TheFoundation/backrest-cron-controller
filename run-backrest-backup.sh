#!/bin/bash
echo "0%"
which apk &>/dev/null && { 
which jq     &>/dev/null || apk add jq
which curl   &>/dev/null || apk add curl
which restic &>/dev/null || apk add restic
which ionice &>/dev/null || apk add ionice
}

which curl &>/dev/null || echo "NO CURL"
which curl &>/dev/null || exit 1
which jq   &>/dev/null || echo "NO JQ"
which jq   &>/dev/null || exit 1

timestamp_nanos() { if [[ $(date -u +%s%N|grep ^[0-9] |wc -c) -eq 20  ]]; then date -u +%s%N;else expr $(date -u +%s) "*" 1000 "*" 1000 "*" 1000 ; fi ; } ;
LOGGFILE=NONE
function log() { 
	[[ "$LOGGFILE" = "NONE" ]] && ( echo "$@" )
	[[ "$LOGGFILE" = "NONE" ]] || ( echo "$@" |tee "$log_file" &>/dev/null)
	}
MYPID=$$
[[ -z "${INFLUX_URL}" ]] && echo "Not sending to influx"
echo "FAIL" > /tmp/backrest_status_$DOMAIN_$PLAN_$MYPID

 test -e /tmp/backrest_stats_sending_$DOMAIN_$PLAN && ( grep -q "${MYPID}" /tmp/backrest_stats_sending_$DOMAIN_$PLAN  ||  { 
	 
	# check if the sender is still alive
	SENDPID=
	test -e /tmp/backrest_stats_sending_$DOMAIN_$PLAN && SENDPID=$(cat /tmp/backrest_stats_sending_$DOMAIN_$PLAN )
	
	[[ -z "$SENDPID" ]] || ( 
	   ( (ps -ALFc||ps w)|grep backrest) |grep $SENDPID  || echo "stats sender for $DOMAIN_$PLAN  seems killed , taking over"
	   ( (ps -ALFc||ps w)|grep backrest) |grep $SENDPID  || rm /tmp/backrest_stats_sending_$DOMAIN_$PLAN
	   )
	
 }
 )
function get_json_status_all() {
[[ ${DEBUGME} = true ]] && echo getting ops from domain $1 with user auth $2

#json_res=$(
curl -kL -X POST  -s -u "$2" 'https://'"$1"'/v1.Backrest/GetOperations' --data '{"selector": {}}' -H 'Content-Type: application/json'|jq -c .operations[]
#)
#echo "$res"|jq .
}

function get_json_status_by_plan() {
[[ ${DEBUGME} = true ]] && echo getting ops from domain $1 with user auth $2 for plan $3 
curl -kL -X POST  -s -u "$2" 'https://'"$1"'/v1.Backrest/GetOperations'  --data '{"selector": {"planId": "'"$3"'"}}' -H 'Content-Type: application/json'|jq -c .operations[]|grep '"planId":"'"$3"
}
function send_influx_data() { 
  #echo "sending influx " >&2
  [[ -z ${INFLUX_URL} ]] || {
  [[ -z ${INFLUX_TOKEN} ]] || curl -s -XPOST --header "Authorization: Token ${INFLUX_TOKEN}" "${INFLUX_URL}" --data-binary @- 
  [[ -z ${INFLUX_AUTH}  ]] || curl -s -XPOST -u "${INFLUX_AUTH}" "${INFLUX_URL}" --data-binary @- 
  }
}

FLOW_ID=0
current_state=$(get_json_status_all "$DOMAIN" "$AUTH" "$PLAN" )
inital_state="$current_state"
#echo search '"planId":"'"$PLAN" 

INSTANCE_READY=false
export STATS_ONLY=false
echo "$current_state"|grep INPROGRESS |wc -l |grep -q "^0$" && INSTANCE_READY=true
## assume readiness if same plan is running
(echo "$current_state"|grep INPROGRESS -q ) && (echo "$current_state"|grep INPROGRESS  |grep -q  '"planId":"'"$PLAN")  && log "BACKUP_RUNNING for curent plan"
(echo "$current_state"|grep INPROGRESS -q ) && (echo "$current_state"|grep INPROGRESS  |grep -q  '"planId":"'"$PLAN")  && { INSTANCE_READY=true; STATS_ONLY=true ; }

echo "$current_state"|grep INPROGRESS  | grep -q  '"planId":"'"$PLAN" && FLOW_ID=$(echo "$current_state"|grep INPROGRESS  |grep  '"planId":"'"$PLAN" |jq -r .flowId )
[[ -z ${FLOW_ID} ]] && FLOW_ID=0
[[ -z ${FLOW_ID} ]] || ( [[ ${FLOW_ID} = 0 ]] || echo "FLOW_ID:"$FLOW_ID )

#echo "$INSTANCE_READY"
while [[ ${INSTANCE_READY}  = "false" ]] ;do 
   log waiting for instance tasks
   echo "1%" 
   sleep 60
   current_state=$(get_json_status_all "$DOMAIN" "$AUTH" "$PLAN" )
   TEMP_READY=false
   (echo "$current_state"|grep INPROGRESS |wc -l )|grep -q "^0$" && TEMP_READY=true
   echo "$current_state"|grep INPROGRESS|grep "operationBackup"|grep  -q '"flowId":"'"${FLOW_ID}" && TEMP_READY=true
   [[ ${TEMP_READY}  = "true" ]] && {
	   sleep 20;
	   current_state=$(get_json_status_all "$DOMAIN" "$AUTH" "$PLAN" )
	   (echo "$current_state"|grep INPROGRESS -q ) || 	   log unlock
	   (echo "$current_state"|grep INPROGRESS |wc -l) |grep -q "^0$" && INSTANCE_READY=true
	   ## assume readiness if same plan is running
	   echo "$current_state"|grep INPROGRESS|grep "operationBackup"|grep  -q '"flowId":"'"${FLOW_ID}" && { INSTANCE_READY=true; export STATS_ONLY=true ; } 
	   echo -n ; }
done

current_state=$(get_json_status_all "$DOMAIN" "$AUTH" "$PLAN" )
(echo "$current_state"|grep INPROGRESS |wc -l) |grep -q "^0$" && INSTANCE_READY=true
## assume readiness if same plan is running
echo "$current_state"|grep INPROGRESS|grep "operationBackup"|grep  -q '"flowId":"'"${FLOW_ID}" && { INSTANCE_READY=true; export STATS_ONLY=true ; } 
## intance ready

## first check for failed backups in the repo itself
REPO_ID=$(echo "$current_state"|grep '"planId":"'"$PLAN"'"'|tail -n10|jq -r .repoId|tail -n1)
[[ -z "${REPO_ID}" ]] || {
  
   ABORTED_FOUND=false
   for check_plan in $(( echo "$PLAN";echo "$current_state"|grep '"repoId":"'"${REPO_ID}"'"'|grep operationBackup|jq -r .planId  )|sort -u ) ; do 
      echo "$current_state"|grep '"repoId":"'"${REPO_ID}"'"'|grep operationBackup|grep '"planId":"'"${check_plan}"'"'|tail -n1|grep -q -e "task was interrupted" -e "STATUS_ERROR" -e "cancellation or instance shutdown" && ABORTED_FOUND=true
   done
   NO_BACKUP_RUNNING=true
   (echo "$current_state"|grep INPROGRESS -q ) && (echo "$current_state"|grep INPROGRESS  |grep -q  '"planId":"'"$PLAN")  && NO_BACKUP_RUNNING=false

   [[ "${NO_BACKUP_RUNNING}" = "true" ]] && [[ "$ABORTED_FOUND" = "true" ]] && {
       log running repair index in $REPO_ID .. unlocking:
       #log curl -kLs -X POST  -u "${AUTH}" "https://${DOMAIN}/v1.Backrest/RunCommand" --data '{"repoId": "'"${REPO_ID}"'","command": "unlock"}' -H 'Content-Type: application/json'  
       curl -kLs -X POST  -u "${AUTH}" "https://${DOMAIN}/v1.Backrest/RunCommand" --data '{"repoId": "'"${REPO_ID}"'","command": "unlock"}' -H 'Content-Type: application/json' 
       echo
       sleep 10
       echo "triggering repair index"
       curl -kLs -X POST  -u "${AUTH}" "https://${DOMAIN}/v1.Backrest/RunCommand" --data '{"repoId": "'"${REPO_ID}"'","command": "repair index"}' -H 'Content-Type: application/json' 
       sleep 5
       TEMP_READY=false
       echo "waiting for index repair"
       while [[ ${TEMP_READY}  = "false" ]] ;do 
          get_json_status_all "$DOMAIN" "$AUTH" "$PLAN" |grep -q INPROGRESS || TEMP_READY=true
          sleep 15
       done
       }
   }
 
[[ ${STATS_ONLY}  = "false" ]] && {
   #(echo "$current_state"|grep INPROGRESS -q ) && (echo "$current_state"|grep INPROGRESS  |grep -q  '"planId":"'"$PLAN")  && exit 1
   
   
   log BACKUP_STARTING
   curl -kL -X POST  -u "${AUTH}" "https://${DOMAIN}/v1.Backrest/Backup" --data '{"value":"'"${PLAN}"'"}' -H 'Content-Type: application/json' &>/tmp/backrest_output_backupStart_$DOMAIN_$PLAN  &
   INSTANCE_READY=false
   }
echo "2%"

while [[ ${INSTANCE_READY}  = "false" ]] ;do 
current_state=$(get_json_status_all "$DOMAIN" "$AUTH" "$PLAN" )
(echo "$current_state"|grep INPROGRESS | grep -q  '"planId":"'"$PLAN" |wc -l) |grep -q "^0$" && INSTANCE_READY=true
sleep 5
done
log BACKUP_RUNNING
echo "$current_state"|grep INPROGRESS  | grep -q  '"planId":"'"$PLAN" && FLOW_ID=$(echo "$current_state"|grep INPROGRESS  |grep  '"planId":"'"$PLAN" |jq -r .flowId )
[[ -z ${FLOW_ID} ]] && FLOW_ID=0
[[ -z ${FLOW_ID} ]] || ( [[ ${FLOW_ID} = 0 ]] || echo "FLOW_ID:"$FLOW_ID )
sleep 1

current_state=$(get_json_status_all "$DOMAIN" "$AUTH" "$PLAN" )
#(echo "$current_state"|grep INPROGRESS -q ) || INSTANCE_READY=true

echo "3%"
[[ ${FLOW_ID} = 0 ]] || {
	grep -q ^${FLOW_ID}$ /tmp/backrest_cur_flow_$DOMAIN_$PLAN  &>/dev/null ||  ( echo "${FLOW_ID}" > /tmp/backrest_cur_flow_$DOMAIN_$PLAN)
	}
[[ ${FLOW_ID} = 0 ]] || { [[ -z ${FLOW_ID} ]]  && ( echo "${FLOW_ID}" > /tmp/backrest_cur_flow_$DOMAIN_$PLAN ) } 

## send initial influx data
(echo "restic_backup_percent,host=$DOMAIN,repo=$PLAN value=100 $mystamp"
 echo "restic_backup_filesDone,host=$DOMAIN,repo=$PLAN value=0 $mystamp"
 echo "restic_backup_bytesDone,host=$DOMAIN,repo=$PLAN value=0 $mystamp"
)  |grep -v ^$| send_influx_data || (log  "FAILED SENDING INFLUX";log "$influx_output") & 

test -e /tmp/backrest_stats_sending_$DOMAIN_$PLAN || (
echo "${MYPID}" > /tmp/backrest_stats_sending_$DOMAIN_$PLAN
    while (test -e /tmp/backrest_stats_sending_$DOMAIN_$PLAN && grep -q "${MYPID}" /tmp/backrest_stats_sending_$DOMAIN_$PLAN );do 
    log status running $(date -u);
    status_state=$( get_json_status_by_plan "$DOMAIN" "$AUTH" "$PLAN" |grep -e STATUS_SUCCESS -e STATUS_ERROR -e INPROGRESS|grep  '"planId":"'"$PLAN" )
    
    #echo "$status_state"
    #echo "$status_state"|grep INPROGRESS
    echo "$status_state"|grep INPROGRESS|grep "operationBackup"  |grep -q lastStatus && (
    ## a backup is running
    echo "running backup found"
    
    [[ ${FLOW_ID} = 0 ]] && { 
      #re-detect flow id if not found
      echo "$status_state"|grep INPROGRESS  |grep -q  '"planId":"'"$PLAN" && FLOW_ID=$(echo "$current_state"|grep INPROGRESS  |grep  '"planId":"'"$PLAN" |jq -r .flowId )
      [[ -z ${FLOW_ID} ]] && FLOW_ID=0
      [[ ${FLOW_ID} = 0 ]] || { [[ -z ${FLOW_ID} ]]  && ( echo "${FLOW_ID}" > /tmp/backrest_cur_flow_$DOMAIN_$PLAN ) } 
      }
    STATS_PERC=
    ### re-fetch in 10 seconds if no lastStatus
    #echo "$status_state"| grep -e INPROGRESS|grep  '"planId":"'"$PLAN"| grep operationBackup |grep lastStatus -q && { 
    #  sleep 10
    #  log re-fetch status
    #  status_state=$( get_json_status_by_plan "$DOMAIN" "$AUTH" "$PLAN" |grep -e STATUS_SUCCESS -e STATUS_ERROR -e INPROGRESS|grep  '"planId":"'"$PLAN" )
    #}
    echo "$status_state"| grep -e INPROGRESS|grep  '"planId":"'"$PLAN"| grep operationBackup |grep lastStatus -q && { 
      restic_stats=$(echo "$status_state"| grep -e INPROGRESS|grep  '"planId":"'"$PLAN"| jq .operationBackup.lastStatus.status)
      #echo RAWSTATS: "$restic_stats"
         STATS_PERC=$(echo "$restic_stats"|jq .percentDone   )
         [[ ${STATS_PERC} = "null" ]] && STATS_PERC=""
         [[ -z "${STATS_PERC}" ]] || {
            STATS_FILS=$(echo "$restic_stats"|jq -r .totalFiles )
            STATS_FILC=$(echo "$restic_stats"|jq -r .filesDone  )
            STATS_BYTS=$(echo "$restic_stats"|jq -r .totalBytes )
            STATS_BYTC=$(echo "$restic_stats"|jq -r .bytesDone  )
            STATS_CURF=$(echo "$restic_stats"|jq -r .currentFile)
            mystamp=$(timestamp_nanos)
            influx_output=$(
            [[ -z "${STATS_PERC}" ]] || echo "restic_backup_percent,host=$DOMAIN,repo=$PLAN value=$STATS_PERC $mystamp"
            [[ -z "${STATS_FILS}" ]] || echo "restic_backup_totalFiles,host=$DOMAIN,repo=$PLAN value=$STATS_FILS $mystamp"
            [[ -z "${STATS_FILC}" ]] || echo "restic_backup_filesDone,host=$DOMAIN,repo=$PLAN value=$STATS_FILC $mystamp"
            [[ -z "${STATS_BYTS}" ]] || echo "restic_backup_totalBytes,host=$DOMAIN,repo=$PLAN value=$STATS_BYTS $mystamp"
            [[ -z "${STATS_BYTC}" ]] || echo "restic_backup_bytesDone,host=$DOMAIN,repo=$PLAN value=$STATS_BYTC $mystamp"
         )
         
         #echo "$influx_output" 
         echo "$influx_output" |grep -v ^$| send_influx_data || (log  "FAILED SENDING INFLUX";log "$influx_output") &
         }
         [[ -z "${STATS_PERC}" ]] || (
            [[ "${FLOAT_PERC}" = "true" ]] || echo $( jq -n "100*$STATS_PERC" |cut -d. -f1)"%"
            [[ "${FLOAT_PERC}" = "true" ]] && echo $( jq -n "100*$STATS_PERC" )"%"
            )
           }

      )
    echo "$status_state"| grep -e INPROGRESS|grep operationBackup | grep  '"planId":"'"$PLAN" -q || rm /tmp/backrest_stats_sending_$DOMAIN_$PLAN
    ## at the end of a backup
    [[ ${FLOW_ID} = 0 ]] || test -e /tmp/backrest_stats_sending_$DOMAIN_$PLAN || { 
		log  will send FINAL_STATS in 60s
        sleep 60
        status_state=$( get_json_status_by_plan "$DOMAIN" "$AUTH" "$PLAN" |grep -e STATUS_SUCCESS -e STATUS_ERROR -e INPROGRESS|grep  '"planId":"'"$PLAN" )
        echo "$status_state"  |grep "operationBackup"|grep -e STATUS_SUCCESS -e STATUS_ERROR |grep  -q '"flowId":"'"${FLOW_ID}"  && {
          echo "$status_state"|grep "operationBackup"|grep  -q '"flowId":"'"${FLOW_ID}"|grep -e STATUS_SUCCESS || echo "100%" 
          echo "$status_state"|grep "operationBackup"|grep  -q '"flowId":"'"${FLOW_ID}"|grep -e STATUS_SUCCESS  && {
          final_res=$(echo "$status_state"|grep "operationBackup"|grep -e STATUS_SUCCESS |grep  '"flowId":"'"${FLOW_ID}")
          restic_stats=$(echo "$final_res"|jq .operationBackup.lastStatus.summary)
          mystamp=$(timestamp_nanos)
          STATS_DURA=$(echo "$restic_stats"|jq .totalDuration )
          SNAP_ID=$(echo "$restic_stats"   |jq -r .snapshotId )
          [[ "${SNAP_ID}" = "null" ]] && SNAP_ID=
          [[ -z "${SNAP_ID}" ]] && { 
              log BACKUP in $PLAN did not seem to finish
              echo "BACKUP in $PLAN did not seem to finish"  > /tmp/backrest_status_$DOMAIN_$PLAN_$MYPID 
          }
          [[ -z "${SNAP_ID}" ]] || { 
                      log BACKUP in $PLAN resulted in $SNAP_ID
                      [[ "${STATS_ONLY}" = "true" ]]  || ( echo "FAIL other backup of same plan was still running"  > /tmp/backrest_status_$DOMAIN_$PLAN_$MYPID )
                      [[ "${STATS_ONLY}" = "false" ]] || ( echo "OK BACKUP OF $DOMAIN / $PLAN SUCCEEDED "  > /tmp/backrest_status_$DOMAIN_$PLAN_$MYPID )            
           }

          
          [[ -z "${STATS_DURA}" ]] || { 
                    influx_output=$(
                        [[ -z "${SNAP_ID}" ]] || echo "restic_backup_percent,host=$DOMAIN,repo=$PLAN value=100 $mystamp"
                        echo "restic_backup_duration_seconds,host=$DOMAIN,repo=$PLAN,snapshot=$SNAP_ID value=${STATS_DURA} $mystamp"
                        echo "restic_backup_added_to_repo,host=$DOMAIN,repo=$PLAN,snapshot=$SNAP_ID value="$(echo "$restic_stats"|jq -r .dataAdded )" $mystamp"
                        echo "restic_backup_dirs_new,host=$DOMAIN,repo=$PLAN,snapshot=$SNAP_ID value="$(echo "$restic_stats"|jq -r .dirsNew )" $mystamp"
                        echo "restic_backup_files_new,host=$DOMAIN,repo=$PLAN,snapshot=$SNAP_ID value="$(echo "$restic_stats"|jq -r .filesNew )" $mystamp"
                        echo "restic_backup_processed_files,host=$DOMAIN,repo=$PLAN,snapshot=$SNAP_ID value="$(echo "$restic_stats"|jq -r .totalFilesProcessed )" $mystamp"
                        echo "restic_backup_processed_size_bytes,host=$DOMAIN,repo=$PLAN,snapshot=$SNAP_ID value="$(echo "$restic_stats"|jq -r .totalBytesProcessed )" $mystamp"
                       )
                      [[ "${STATS_ONLY}" = "false" ]] || ( echo "OK BACKUP OF $DOMAIN / $PLAN SUCCEEDED WITH "$(echo "$restic_stats"|jq -r .filesNew ) " newFiles,"$(echo "$restic_stats"|jq -r .totalBytesProcessed ) " BYTES_DONE IN ${STATS_DURA} s"  > /tmp/backrest_status_$DOMAIN_$PLAN_$MYPID )            
                     echo "$influx_output" |grep -v ^$| send_influx_data|| (log  "FAILED SENDING FINAL INFLUX";log "$influx_output")
                   }
          
          
          echo "95%"
         }
      }
    }
    echo "$status_state"| grep -e INPROGRESS|grep  '"planId":"'"$PLAN"| grep operationBackup  -q && sleep 20;
    echo "$status_state"| grep -e INPROGRESS|grep  '"planId":"'"$PLAN"| grep operationBackup |grep lastStatus -q || sleep 5
    sleep 10
    done
) &
wait

## end part
[[ ${FLOW_ID} = 0 ]] && ( (echo $( cat /tmp/backrest_cur_flow_$DOMAIN_$PLAN; echo FLOW_ID_NOT_FOUND ) ) >  /tmp/backrest_cur_flow_$DOMAIN_$PLAN )
test -e /tmp/backrest_cur_flow_$DOMAIN_$PLAN && rm  /tmp/backrest_cur_flow_$DOMAIN_$PLAN
myres=$(cat /tmp/backrest_status_$DOMAIN_$PLAN_$MYPID)
rm /tmp/backrest_status_$DOMAIN_$PLAN_$MYPID
echo "97%"
echo "$myres"|grep FAIL -q ||  { 
    # successful backup, calculate repo stats
    
    echo "triger stats generation"
    echo "98%"
    curl -kLs -X POST  -u "${AUTH}" "https://${DOMAIN}/v1.Backrest/DoRepoTask" --data '{"repoId": "s3-bob","task": "TASK_STATS"}' -H 'Content-Type: application/json'

    }
echo "$myres"|grep FAIL && exit 1
echo 100%
exit 0