#!/usr/bin/zsh

sshkey_id="123456789"
region="nyc1"
instancecount="10"
instancesize="s-2vcpu-2gb"
instancetag="loadtest"
imageid="centos-7-x64"
attackrate="100"
attackduration="30s"
plotpath="/mnt/c/Users/Name/Downloads"

echo "Creating Vegeta instances!"
doctl compute droplet create ${region}-{1..${instancecount}} --region ${region} --image ${imageid} --size ${instancesize} --ssh-keys ${sshkey_id} --tag-name ${instancetag} --wait

echo "Getting new instance IPs!"
iparray=()
for __ip in $(doctl compute droplet list --tag-name ${instancetag} --output json | jq -r '.[] | .networks.v4[] | select(.type=="public") | .ip_address'); do
    iparray+=( "${__ip}" )
done

echo "Purging current IPs from known hosts!"
for __ip in ${iparray[@]}
do
    ssh-keygen -qf "~/.ssh/known_hosts" -R "${__ip}" 2>/dev/null
done

echo "Adding Vegeta hosts file entries!"
echo "###LOADTESTBEGIN###\n$(doctl compute droplet list --tag-name loadtest --no-header --format PublicIPv4,Name)\n###LOADTESTEND###" >> /etc/hosts

# Need to make this smarter, sleep gets the job done for now.
echo "Waiting for SSH to come online!"
sleep 60

echo "Updating Ansible inventory!"
echo ${(j:\n:)iparray} > inventory

echo "Updating targets!"
ansible-playbook -i inventory update.yml

# Need to add progress bar (pv?) or animation to this.
echo "Attacking!"
PDSH_SSH_ARGS_APPEND="-o StrictHostKeyChecking=no"
PDSH_RCMD_TYPE=ssh pdsh -l root -b -w  $(echo "${(j:,:)iparray}") $(echo "/usr/bin/vegeta attack -rate=${attackrate} -duration=${attackduration} -name=\${HOSTNAME} -targets=targets > result.bin")

# Tried a for loop iterating over ${iparray[@]} but the IPs are causing octet errors with the "pids[${__machine}]=$!" line...
echo "Downloading results!"
for __machine in ${region}-{1..${instancecount}}
do
    scp -o StrictHostKeyChecking=no -q root@${__machine}:~/result.bin ${__machine}.bin &
    pids[${__machine}]=$!
done

echo "Waiting for downloads to complete!"
for __pid in ${pids[*]}
do
    wait ${__pid}
done

echo "Deleting Vegeta instances!"
for __instanceid in $(doctl compute droplet list --tag-name ${instancetag} --output json | jq '.[] | .id'); do 
    doctl compute droplet delete ${__instanceid} --force
done

echo "Deleting Vegeta hosts file entries!"
sed -i '/^###LOADTESTBEGIN###/,/^###LOADTESTEND###/{/^###LOADTESTBEGIN###/!{/^###LOADTESTEND###/!d}}' /etc/hosts
sed -i 's/###LOADTESTBEGIN###//' /etc/hosts
sed -i 's/###LOADTESTEND###//' /etc/hosts

echo "Generating report!"
vegeta report *.bin

echo "Generating plot!"
vegeta plot *.bin > ${plotpath}/plot-$(date +%s).html

echo "Deleting result binaries!"
rm -f ${region}-{1..${instancecount}}.bin
