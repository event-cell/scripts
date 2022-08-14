date=$(date '+%Y-%m-%d')

docker run --rm --volumes-from ${CONTAINER:-core-core-1} -v ${BACKUP_DIR:-~/backup:/backup} debian:buster bash -c "mkdir -p /backup/${date} && cd /data && tar cvfz /backup/${date}/core-data.tar.gz ."
