#!/bin/bash
#
# BACKUP POLICY
# run full backup everyday at am 4:00
# run incremental backup every hour a day
#
# SET CONFIGURE IN CRONTAB
# 0 * * * * /server/scripts/mysql_backup.sh
#
# RESTORE DB USAGE: mysql_backup.sh restorebackup
#
# 2015.10 @zg
#
#full backup at 3 AM
full_backup_at=3
#CHANGE FOLLOWINGS TO CHANGE TARGET DIR WHEN RESTORE
cdate=`date +%Y_%m_%d`
chour=`date +%H`
#old than 3 days backup file will reomoved
REMOVEOVERDAYS=3

bin=$(which innobackupex)
binx=$(which xtrabackup)
bin15=$(which innobackupex-1.5.1)
qpress=$(which qpress)
mysql_port=3306
mysql_cnf=/etc/my.cnf
mysql_data=/mnt/mysql/
mysql_user=root
mysql_pwd=password
#make sure dir not exists when run first time.
mysql_backup_base=/mnt/backup/mysql/base/
mysql_backup_base_dir=$mysql_backup_base$cdate/
mysql_backup_inc_base=/mnt/backup/mysql/inc/
mysql_backup_inc=$mysql_backup_inc_base$cdate/
mysql_backup_inc_dir=$mysql_backup_inc$chour/
is_incremental_enabled=1
xtrabackup_log=/var/log/xtrabackup.log
fullback_tar_name='mysql_full_'${cdate}'.tar.gz'
incrementalback_tar_name='mysql_incremental_'${cdate}'.tar.gz'
cdatetime=`date +"%Y-%m-%d %H:%M:%S"`

check_env(){
	if [ ! -f $bin ];then
		echo $bin ' not found.'
		exit
	fi
	if [ ! -f $binx ];then
		echo $binx ' not found.'
		exit
	fi
	if [ ! -f $bin15 ];then
		echo $bin15 ' not found.'
		exit
	fi
	if [ ! -f $mysql_cnf ];then
		echo $mysql_cnf ' not found.'
		exit
	fi
	if [ ! -d $mysql_data ];then
		echo $mysql_data ' dir not found.'
		exit
	fi
	if [ ! -d $mysql_backup_base ];then
		mkdir -p $mysql_backup_base
	fi
	if [ ! -d $mysql_backup_inc ];then
		mkdir -p $mysql_backup_inc
	fi
}

fullback(){
	if [ ! -d $mysql_backup_base_dir ];then
		if [ $chour -eq $full_backup_at ];then
			echo	
			echo '==============================='
			echo '>>> Run full backup once:'
			echo '==============================='
			echo =========================Run full backup========================== >>$xtrabackup_log 2>&1
			$bin --compress --compress-thread=4 --defaults-file=$mysql_cnf --user=$mysql_user --password=$mysql_pwd --no-timestamp $mysql_backup_base_dir >>$xtrabackup_log 2>&1
		else
			echo 'Error,full backup only run at '$full_backup_at
			echo 'Error,full backup only run at '$full_backup_at >> $xtrabackup_log 2>&1
		fi
	else
		echo 'Ignore full backup.target dir is exists:'$mysql_backup_base_dir
		echo 'Ignore full backup.target dir is exists:'$mysql_backup_base_dir >>$xtrabackup_log 2>&1
	fi
}

incrementalbackup(){
	if [ ! -d $mysql_backup_base_dir ];then
		echo 'Error,base backup dir not exists: '${mysql_backup_base_dir}',incremental backup exit.'
		echo 'Error,base backup dir not exists: '${mysql_backup_base_dir}',incremental backup exit.' >> $xtrabackup_log 2>&1
		return 1	
	fi
	if [ -d $mysql_backup_inc_dir ];then
		echo 'Error,incremental backup dir exists: '${mysql_backup_inc_dir}
		echo 'Error,incremental backup dir exists: '${mysql_backup_inc_dir} >> $xtrabackup_log 2>&1
		return 1	
	fi

	if [ ! -d $mysql_backup_inc_dir ];then
		echo
		echo '==============================='
		echo '>>> Run incrementalbackup at' $chour  ':'
		echo '==============================='
		echo =========================Run incremental backup at $chour ========================== >>$xtrabackup_log 2>&1
		#do an incremental backup
		$bin --compress --compress-thread=4 --defaults-file=$mysql_cnf --user=$mysql_user --password=$mysql_pwd --no-timestamp --incremental-basedir=$mysql_backup_base_dir --incremental $mysql_backup_inc_dir >>$xtrabackup_log 2>&1

	fi	
}

preparemain(){
	#prepare twice
	echo
	echo '==============================='
	echo '>>> Run full backup prepare first:'
	echo '==============================='
	echo =========================Run full backup prepare first========================== >>$xtrabackup_log 2>&1
	$binx --defaults-file=$mysql_cnf --prepare --target-dir=$mysql_backup_base_dir >>$xtrabackup_log 2>&1
	echo '==============================='
	echo '>>> Run full backup prepare second:'
	echo '==============================='
	echo =========================Run full backup prepare second========================== >>$xtrabackup_log 2>&1
	$binx --defaults-file=$mysql_cnf --prepare --target-dir=$mysql_backup_base_dir >>$xtrabackup_log 2>&1 
}

decompress(){
	cd $mysql_backup_base_dir  
	for bf in `find . -iname "*\.qp"`; do $qpress -d $bf $(dirname $bf) && rm $bf; done
	cd $mysql_backup_inc_dir
	for bf in `find . -iname "*\.qp"`; do $qpress -d $bf $(dirname $bf) && rm $bf; done
	#for XtraBackup 2.1.4
	#innobackupex --decompress /data/backup/2013-08-01_11-24-04/
}


preparelog(){
	#decompress
	decompress

	#prepare main backup first
	preparemain

	#replay the committed transactions on each backup
	echo
	echo '==============================='
	echo '>>> Run incremental backup: committed transaction to main backup'
	echo '==============================='
	echo =========================Run incremental backup:apply log to main backup========================== >>$xtrabackup_log 2>&1
	$bin --defaults-file=$mysql_cnf --use-memory=1G --apply-log --redo-only $mysql_backup_base_dir  >>$xtrabackup_log 2>&1

	#apply the incremental backup to the base backup
	echo
	echo '==============================='
	echo '>>> Run incremental backup: merge incremental log to the base backup'
	echo '==============================='
	echo =========================Run incremental backup: merge incremental log========================== >>$xtrabackup_log 2>&1
	#loop all incremental backup files in the save day and merge it
	for f in `ls $mysql_backup_inc`
	do
		$bin --defaults-file=$mysql_cnf --use-memory=1G --apply-log --redo-only $mysql_backup_base_dir --incremental-dir $mysql_backup_inc$f/  >>$xtrabackup_log 2>&1
	done;	
	#put all the parts together, you can prepare again the full backup (base + incrementals) once again to rollback the pending transactions
	echo
	echo '==============================='
	echo '>>> Put all incremental backup together:'
	echo '==============================='
	echo =========================Put all log together========================== >>$xtrabackup_log 2>&1
	#this step will also copy MYISAM table
	$bin15 --defaults-file=$mysql_cnf --use-memory=1G --apply-log $mysql_backup_base_dir  >>$xtrabackup_log 2>&1
}


restorebackup(){
	#step 1: decompress and prepare log
	preparelog
	#step 2: hare copy
	$bin --copy-back $mysql_backup_base_dir
	chown -R mysql:mysql $mysql_data
}

date2stamp () {
    date +%s -d "$1"
}

dateDiff (){
    case $1 in
        -s)   sec=1;      shift;;
        -m)   sec=60;     shift;;
        -h)   sec=3600;   shift;;
        -d)   sec=86400;  shift;;
        *)    sec=86400;;
    esac
    dte1=$(date2stamp $1)
    dte2=$(date2stamp $2)
    diffSec=$((dte2-dte1))
    if ((diffSec < 0)); then abs=-1; else abs=1; fi
    echo $((diffSec/sec*abs))
}

deleteold(){
	cdate=`date +%Y%m%d`
	if [ ! $# -eq 1 ];then
		echo 'deleteold error:wrong arguments.'
		return 1	
	fi
	echo 'Check old file at '$1
	for f in `ls $1`
	do
			arr=(${f//\-/ })
			arr_size=${#arr[@]}
			if [ $arr_size -ne 3 ];then continue; fi;
			foo=${arr[2]}
			foo_arr=(${foo//\./ })
			fdate=${foo_arr[0]}

			days=`dateDiff -d "$cdate" "$fdate"`
			#echo $days
			if [ $days -ge $REMOVEOVERDAYS ];then
				if [ -f $1$f ];then
					echo "delete old backup..."$1$f >> $xtrabackup_log
					#rm -f $1$f
				fi
			fi;
	done
}

deleteold2(){
cd $mysql_backup_base && find ./ -maxdepth 1 -type d -ctime +$( expr $REMOVEOVERDAYS - 1 ) -regex './[0-9][0-9][0-9][0-9]_[0-9][0-9]_[0-9][0-9]' -exec rm -rf {} \;

cd $mysql_backup_inc_base && find ./ -maxdepth 1 -type d -ctime +$( expr $REMOVEOVERDAYS - 1 ) -regex './[0-9][0-9][0-9][0-9]_[0-9][0-9]_[0-9][0-9]' -exec rm -rf {} \;
}

#
#main procedure
#
if [ -f $bin ];then
	echo $cdatetime =========================BEGIN========================== >>$xtrabackup_log 2>&1

	if [ $1 == "" ];then
		check_env
		fullback
		incrementalbackup
		deleteold2
	fi;
	if [ $1 == "restorebackup" ];then
		echo "restore backup"
		restorebackup
	fi;

	#deleteold $mysql_backup_base
	#deleteold $mysql_backup_inc_base

	echo $cdatetime =========================END========================== >>$xtrabackup_log 2>&1
else
	echo 'innobackupex not found.'
fi



