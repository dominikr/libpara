#
# Regular cron jobs for the libpara package
#
0 4	* * *	root	[ -x /usr/bin/libpara_maintenance ] && /usr/bin/libpara_maintenance
