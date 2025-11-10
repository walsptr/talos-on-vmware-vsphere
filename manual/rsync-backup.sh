#!/bin/bash
echo "Running rsync on $(date '+%Y-%m-%d_%H-%M-%S')" >> /var/log/rsync-backup.log
rsync -av --delete /home/ubuntu/ ubuntu@node:/home/ubuntu/ >> /var/log/rsync-backup.log 2>&1
rsync -av --delete /home/ubuntu/.kube/ ubuntu@node:/home/ubuntu/.kube/    >> /var/log/rsync-backup.log 2>&1
echo "Rsync completed on $(date '+%Y-%m-%d_%H-%M-%S')" >> /var/log/rsync-backup.log