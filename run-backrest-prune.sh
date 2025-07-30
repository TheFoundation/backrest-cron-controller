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
echo STARTING >  /tmp/backrest_prune_status_$DOMAIN_$REPOID_$MYPID

[[ -z "${REPOID}" ]] && echo "your did not set REPOID"
[[ -z "${REPOID}" ]] && exit 1
[[ -z "${DOMAIN}" ]] && echo "your did not set DOMAIN"
[[ -z "${DOMAIN}" ]] && exit 1
[[ -z "${AUTH}" ]] && echo "your did not set AUTH"
[[ -z "${AUTH}" ]] && exit 1

[[ -z "${INFLUX_URL}" ]] && echo "Not sending to influx"

function get_json_status_all() {
[[ ${DEBUGME} = true ]] && echo getting ops from domain $1 with user auth $2

#json_res=$(
curl -kL -X POST  -s -u "$2" 'https://'"$1"'/v1.Backrest/GetOperations' --data '{"selector": {}}' -H 'Content-Type: application/json'|jq -c .operations[]
#)
#echo "$res"|jq .
}

function get_json_status_by_repo() {
[[ ${DEBUGME} = true ]] && echo getting ops from domain $1 with user auth $2 for plan $3 
curl -kL -X POST  -s -u "$2" 'https://'"$1"'/v1.Backrest/GetOperations'  --data '{"selector": {"repoId": "'"$3"'"}}' -H 'Content-Type: application/json'|jq -c .operations[]|grep '"repoId":"'"$3"
}
function send_influx_data() { 
  #echo "sending influx " >&2
  [[ -z ${INFLUX_URL} ]] || {
  [[ -z ${INFLUX_TOKEN} ]] || curl -s -XPOST --header "Authorization: Token ${INFLUX_TOKEN}" "${INFLUX_URL}" --data-binary @- 
  [[ -z ${INFLUX_AUTH}  ]] || curl -s -XPOST                             -u "${INFLUX_AUTH}" "${INFLUX_URL}" --data-binary @- 
  }
}

function send_restback_dashboard_to_influx() { 
  log send_restback_dashboard_to_influx
  dashboard_summary=$(curl -kL -X POST  -s -u "$2" 'https://'"$1"'/v1.Backrest/GetSummaryDashboard' --data '{}' -H 'Content-Type: application/json')
repo_statdata=$(
  echo "$dashboard_summary" |jq .repoSummaries[] -c |grep -v null |while read reposum;do 
#echo "$reposum"
     myrepo=$(echo "$reposum" |jq -r .id)
   ( echo "restic_stats_backups_failed_30days,host=$DOMAIN,repo=${myrepo} value="$(echo "$reposum" |jq -r .backupsFailed30days || echo -n 0)" "$(timestamp_nanos)
     echo "restic_stats_backups_success_30days,host=$DOMAIN,repo=${myrepo} value="$(echo "$reposum" |jq -r .backupsSuccessLast30days)" "$(timestamp_nanos)
     echo "restic_stats_bytes_added_30days,host=$DOMAIN,repo=${myrepo} value="$(echo "$reposum" |jq -r .bytesAddedLast30days)" "$(timestamp_nanos)
     echo "restic_stats_bytes_added_avg,host=$DOMAIN,repo=${myrepo} value="$(echo "$reposum" |jq -r .bytesAddedAvg)" "$(timestamp_nanos)
     echo "restic_stats_bytes_scanned_30days,host=$DOMAIN,repo=${myrepo} value="$(echo "$reposum" |jq -r .bytesScannedLast30days)" "$(timestamp_nanos)
     echo "restic_stats_bytes_scanned_avg,host=$DOMAIN,repo=${myrepo} value="$(echo "$reposum" |jq -r .bytesScannedAvg)" "$(timestamp_nanos) ) | grep -v  -e "value= " -e value=null
done  
)

echo "$repo_statdata" | send_influx_data|grep error && ( log "failed sending restback dashboard to influx" ;echo "$repo_statdata" )
}

FLOW_ID=0
echo 0 > /tmp/backrest_cur_flow_$DOMAIN_$PLAN

current_state=$(get_json_status_all "$DOMAIN" "$AUTH" "$REPOID" )
inital_state="$current_state"
#echo search '"planId":"'"$REPOID" 

INSTANCE_READY=false
echo "$current_state"|grep INPROGRESS |wc -l |grep -q "^0$" && INSTANCE_READY=true

(echo "$current_state"|grep INPROGRESS -q ) && (echo "$current_state"|grep INPROGRESS  |grep -q  '"repoId":"'"$REPOID")  && ( 
    log "INSTANCE RUNNING for current repo" 
    )
(echo "$current_state"|grep INPROGRESS -q ) && (echo "$current_state"|grep INPROGRESS  |grep -q  '"repoId":"'"$REPOID")  || (
  ## send initial influx data
  (echo "restic_purge_percent,host=$DOMAIN,repo=$REPOID value=0 $mystamp"
  )  |grep -v ^$| send_influx_data |grep error &&  (log  "FAILED SENDING INFLUX";log "$influx_output") & 

)

send_restback_dashboard_to_influx "$DOMAIN" "$AUTH"


#echo "$INSTANCE_READY"
while [[ ${INSTANCE_READY}  = "false" ]] ;do 
   log waiting for instance tasks
   echo "1%" 
   sleep 20
	   current_state=$(get_json_status_all "$DOMAIN" "$AUTH" "$REPOID" )
	   (echo "$current_state"|grep INPROGRESS -q ) || 	   log unlock
	   (echo "$current_state"|grep INPROGRESS |wc -l) |grep -q "^0$" && INSTANCE_READY=true
done

current_state=$(get_json_status_all "$DOMAIN" "$AUTH" "$REPOID" )
(echo "$current_state"|grep INPROGRESS |wc -l) |grep -q "^0$" && INSTANCE_READY=true

## intance ready

## first check for failed backups in the repo itself
#REPOID=$(echo "$current_state"|grep '"planId":"'"$REPOID"'"'|tail -n10|jq -r .repoId|tail -n1)
[[ -z "${REPOID}" ]] || {
       log running prune in $REPOID .. unlocking:
       #log curl -kLs -X POST  -u "${AUTH}" "https://${DOMAIN}/v1.Backrest/RunCommand" --data '{"repoId": "'"${REPOID}"'","command": "unlock"}' -H 'Content-Type: application/json'  
       curl -kLs -X POST  -u "${AUTH}" "https://${DOMAIN}/v1.Backrest/RunCommand" --data '{"repoId": "'"${REPOID}"'","command": "unlock"}' -H 'Content-Type: application/json' 
       echo
       sleep 10
       echo "triggering PRUNE"
       statstart=$(date +%s)
       sendres=$(timeout 15 curl -kLs -X POST  -u "${AUTH}" "https://${DOMAIN}/v1.Backrest/DoRepoTask" --data '{"repoId": "'"${REPOID}"'","task": "TASK_PRUNE"}' -H 'Content-Type: application/json' )
       echo "$sendres"|grep  "repo not found" &&  exit 1
       current_state=$( get_json_status_all "$DOMAIN" "$AUTH" "$REPOID" )
       echo "$current_state"|grep INPROGRESS |grep operationPrune  | grep -q  '"repoId":"'"$REPOID" && FLOW_ID=$(echo "$current_state"|grep INPROGRESS  |grep operationPrune |grep  '"repoId":"'"$REPOID" |jq -r .flowId )
       [[ -z ${FLOW_ID} ]] && FLOW_ID=0
       [[ -z ${FLOW_ID} ]] || ( [[ ${FLOW_ID} = 0 ]] || ( 
        #echo "FLOW_ID:"$FLOW_ID
                  grep -q ^${FLOW_ID}$ /tmp/backrest_cur_flow_$DOMAIN_$PLAN  &>/dev/null ||  ( echo "${FLOW_ID}" > /tmp/backrest_cur_flow_$DOMAIN_$PLAN)
         )
        )
       [[ ${FLOW_ID} = 0 ]] || { [[ -z ${FLOW_ID} ]]  && ( echo "0" > /tmp/backrest_cur_flow_$DOMAIN_$PLAN ) } 
       sleep 5
       TEMP_READY=false
       echo "waiting for PRUNE"
       echo 5%
       while [[ ${TEMP_READY}  = "false" ]] ;do 
          current_state=$( get_json_status_all "$DOMAIN" "$AUTH" "$REPOID" )
          echo "$current_state" |grep -q INPROGRESS || TEMP_READY=true
          #echo "$current_state"  | grep '"repoId":"'"$REPOID" 
          echo "$current_state"|grep INPROGRESS |grep operationPrune  | grep -q  '"repoId":"'"$REPOID" && FLOW_ID=$(echo "$current_state"|grep INPROGRESS  |grep operationPrune |grep  '"repoId":"'"$REPOID" |jq -r .flowId )
          [[ -z ${FLOW_ID} ]] && FLOW_ID=0
          [[ -z ${FLOW_ID} ]] || ( [[ ${FLOW_ID} = 0 ]] || ( 
            #echo "FLOW_ID:"$FLOW_ID
                     grep -q ^${FLOW_ID}$ /tmp/backrest_cur_flow_$DOMAIN_$PLAN  &>/dev/null ||  ( echo "${FLOW_ID}" > /tmp/backrest_cur_flow_$DOMAIN_$PLAN)
            )
           )
          [[ ${FLOW_ID} = 0 ]] || { [[ -z ${FLOW_ID} ]]  && ( echo "0" > /tmp/backrest_cur_flow_$DOMAIN_$PLAN ) } 
             
          [[ ${TEMP_READY}  = "false" ]] && sleep 15
       done
       statend=$(date +%s)
       log "restback prune done after in "$(($statend - $statstart))"s"
   }
echo 90%
## end part
FLOW_ID=$(cat /tmp/backrest_cur_flow_$DOMAIN_$PLAN)
[[ -z "$FLOW_ID}" ]] && FLOW_ID=0
[[ -z ${FLOW_ID} ]] || ( [[ ${FLOW_ID} = 0 ]] || ( 
        echo "FLOW_ID:"$FLOW_ID )
[[ ${FLOW_ID} = 0 ]] && ( (echo $( cat /tmp/backrest_purge_flow_$DOMAIN_$REPOID; echo FAIL_FLOW_ID_NOT_FOUND ) ) >  /tmp/backrest_purge_flow_$DOMAIN_$REPOID )
test -e /tmp/backrest_purge_flow_$DOMAIN_$REPOID && rm  /tmp/backrest_purge_flow_$DOMAIN_$REPOID
myres=$(cat /tmp/backrest_prune_status_$DOMAIN_$REPOID_$MYPID)
test -e /tmp/backrest_prune_status_$DOMAIN_$REPOID_$MYPID && rm /tmp/backrest_prune_status_$DOMAIN_$REPOID_$MYPID
echo "94%"
[[ ${FLOW_ID} = 0 ]] && log "no flow id found"
[[ ${FLOW_ID} = 0 ]] ||  { 
    # flow found , calculate repo stats
    [[ -z "${REPOID}" ]] || {
    log "trigger stats generation"
    statstart=$(date +%s)
    curl -kLs -X POST  -u "${AUTH}" "https://${DOMAIN}/v1.Backrest/DoRepoTask" --data '{"repoId": "'"${REPOID}"'","task": "TASK_STATS"}' -H 'Content-Type: application/json' 
    echo;echo "95%" 
    log "wait for stats"
    STATS_RUNNING="false"
       while [[ ${STATS_RUNNING}  = "false" ]] ;do 
          get_json_status_all "$DOMAIN" "$AUTH" "$REPOID" |grep stats |grep '"repoId":"'"${REPOID}"'"'|grep -q INPROGRESS || STATS_RUNNING=true
          [[ ${STATS_RUNNING}  = "false" ]] && sleep 15
       done
     statend=$(date +%s)
     log "restback stats generated in "$(($statend - $statstart))"s"
    [[ -z "${INFLUX_URL}" ]] || {      
      statsres=$( get_json_status_all "$DOMAIN" "$AUTH" "$REPOID"  )
      log "sending restback_repo_stats"
      echo "$statsres" | grep operationStats |grep totalSize|tail -n 10 |while read statline;do 
    #echo "$statline" >&2
    echo "$statline"|grep -q "totalSize" && ( 
     ( 
     myrepo=$(echo "$statline" |jq -r .repoId)
     myendtime=$(echo "$statline" |jq -r .unixTimeEndMs )
        echo "restic_stats_total_size_bytes,host=$DOMAIN,repo=${myrepo} value="$(echo "$statline" |jq -r .operationStats.stats.totalSize)" ${myendtime}000001" 
        echo "restic_stats_total_uncompressed_size_bytes,host=$DOMAIN,repo=${myrepo} value="$(echo "$statline" |jq -r .operationStats.stats.totalUncompressedSize)" ${myendtime}000001"  
        echo "restic_stats_compression_ratio,host=$DOMAIN,repo=${myrepo} value="$(echo "$statline" |jq -r .operationStats.stats.compressionRatio)" ${myendtime}000001"  
        echo "restic_stats_blob_count,host=$DOMAIN,repo=${myrepo} value="$(echo "$statline" |jq -r .operationStats.stats.totalBlobCount)" ${myendtime}000001"   
        echo "restic_stats_snapshot_count,host=$DOMAIN,repo=${myrepo} value="$(echo "$statline" |jq -r .operationStats.stats.snapshotCount)" ${myendtime}000001"   )  | grep -v -e value=null -e "value= "
     ) 
    done | send_influx_data |grep error && echo "failed sending final restic_stats from backrest to influx"

      echo -n ; } ; 
    echo
    }
    echo "98%" 
    send_restback_dashboard_to_influx "$DOMAIN" "$AUTH"
}
echo "99%" 
[[  -z "$HEALTHCHECKSIO" ]] || { 
    echo "$myres"|grep -q FAIL || { echo "sending healthchecks.io  ok" ;curl -s "$HEALTHCHECKSIO"/0 ; } ; 
    echo "$myres"|grep -q FAIL && { echo "sending healthchecks.io err" ;curl -s "$HEALTHCHECKSIO"/1 ; } ; 
}
echo "$myres"|grep FAIL && exit 1
echo 100%
exit 0
