#!/bin/bash
echo "Running rsync on $(date '+%Y-%m-%d_%H-%M-%S')" >> /var/log/rsync-backup.log
rsync -av --delete /home/ubuntu/ ubuntu@node:/home/netadmin/ >> /var/log/rsync-backup.log 2>&1
rsync -av --delete /home/ubuntu/.kube/ ubuntu@node:/home/netadmin/.kube/    >> /var/log/rsync-backup.log 2>&1
echo "Rsync completed on $(date '+%Y-%m-%d_%H-%M-%S')" >> /var/log/rsync-backup.log